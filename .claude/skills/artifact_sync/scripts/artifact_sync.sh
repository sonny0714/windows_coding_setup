#!/bin/bash
# ============================================
#  Artifact Sync — collect/distribute experiment artifacts between servers
#
#  Usage:
#    ./artifact_sync.sh -a collect -p <project> -t all       — collect runs from all active servers
#    ./artifact_sync.sh -a c -p <project> -t all             — short for collect
#    ./artifact_sync.sh -a distribute -p <project> -t all    — distribute models to all active servers
#    ./artifact_sync.sh -a d -p <project> -t all             — short for distribute
#    ./artifact_sync.sh -a c -p <project> -t <server>        — collect from specific server
#    ./artifact_sync.sh -a d -p <project> -t <server> -f     — distribute to server, clear models first
#    ./artifact_sync.sh -a c -p <project> -t all -r <id,id>  — collect only these run_ids
#    ./artifact_sync.sh -a c -p <project> -t all -R - -x weights   — run_ids from stdin, logs only
#    ./artifact_sync.sh -a c -p <project> -t all -r <id> -D outputs/models/<topic>/<sub>
#                                                            — collect straight into the promoted path
#
#  Options:
#    -a <mode>    collect (c) or distribute (d) — required
#    -p <project> target project — required
#    -t <server>  target server — required ("all" = all server_active_status=true servers)
#    -r <ids>     collect only these run_ids (comma/space separated), repeatable
#    -R <file>    collect only run_ids read from a file ("-" = stdin, e.g. run_scan.sh -o ids)
#    -x <what>    collect exclusion, repeatable: weights | check_points | <rsync pattern>
#                   weights      — check_points/ + *.jax  (eval/adaptation runs: logs only)
#                   check_points — check_points/ only     (training runs: final weights kept)
#    -D <path>    collect destination, RELATIVE TO THE PROJECT ROOT — default is
#                 the run store above the repo (artifacts/runs/{project}/).
#                 Use it to land run dirs straight in their promoted home, e.g.
#                 -D outputs/models/pretraining/seed0/xferqoe
#    -n           dry run — list what rsync would transfer, change nothing
#    -f           distribute only: clear remote models/ before transfer
#    -h           show help
#
#  Collect always closes with two reports: run_id → source server for everything
#  that landed, and the requested ids no inspected server had.
#
#  Collect (remote → sync_hub): raw training runs live ABOVE the repo at
#    artifacts/runs/{project}/ (sibling of the project dir), not in-repo.
#    Per server (parallel):
#      1. rsync remote:artifacts/runs/{project}/ → local artifacts/runs_staging/{project}_{server}/
#      2. mv staging files → artifacts/runs/{project}/
#      3. rm staging
#    With -r/-R only the named run_ids transfer, and ids absent on a server are
#    skipped there rather than failing the whole rsync.
#
#  Distribute (sync_hub → remote): promoted models in-repo at outputs/models/.
#    Per server (parallel):
#      1. (-f) rm remote outputs/models/*
#      2. rsync local:{project}/outputs/models/ → remote outputs/models_staging/
#      3. mv staging files → outputs/models/
#      4. rm staging
#
#  Requires:
#    - Must run on sync_hub server
#    - "base_{PROJECT_USER}" docker container running on sync_hub and target servers
#    - rsync installed on all servers
#
#  Path conventions:
#    rsync (host level)  : source_mnt_path paths
#    docker exec (file ops) : target_mnt_path paths
# ============================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
eval "$(python3 "${SCRIPT_DIR}/exec.py" "$(cd "${SCRIPT_DIR}/../../../.." && pwd)/md_files/users/users.yaml" "sonny")"
source "${SCRIPT_DIR}/utils.sh"

_show_help() { sed -n '2,/^# ====.*$/p' "$0" | sed 's/^# \?//'; exit 0; }

# Parse options
MODE=""
TARGET_SERVER=""
TARGET_PROJECT=""
FORCE=false
DRY_RUN=false
SHOW_HELP=false
RUN_IDS=()
EXCLUDE_ARGS=()
COLLECT_DEST=""

while getopts "a:t:p:r:R:x:D:nfh" opt; do
    case $opt in
        a) MODE="$OPTARG" ;;
        D) COLLECT_DEST="$OPTARG" ;;
        t) TARGET_SERVER="$OPTARG" ;;
        p) TARGET_PROJECT="$OPTARG" ;;
        r) IFS=', ' read -r -a _ids <<< "$OPTARG"; RUN_IDS+=("${_ids[@]}") ;;
        R) if [ "$OPTARG" = "-" ]; then mapfile -t _ids; else mapfile -t _ids < "$OPTARG"; fi
           for _id in "${_ids[@]}"; do [ -n "${_id// }" ] && RUN_IDS+=("${_id// }"); done ;;
        x) case "$OPTARG" in
               weights)      EXCLUDE_ARGS+=(--exclude=check_points/ --exclude='*.jax') ;;
               check_points) EXCLUDE_ARGS+=(--exclude=check_points/) ;;
               *)            EXCLUDE_ARGS+=(--exclude="$OPTARG") ;;
           esac ;;
        n) DRY_RUN=true ;;
        f) FORCE=true ;;
        h) SHOW_HELP=true ;;
        *) echo "Usage: $0 -a <collect|distribute> -t <server|all> -p <project> [-r ids] [-R file] [-x what] [-D dest] [-n] [-f] [-h]"; exit 1 ;;
    esac
done

[ "${SHOW_HELP}" = true ] && _show_help

# Validate required options
if [ -z "${TARGET_PROJECT}" ]; then
    echo "[ERROR] -p option required: specify a project"
    exit 1
fi

if [ -z "${TARGET_SERVER}" ]; then
    echo "[ERROR] -t option required: specify a server or 'all'"
    exit 1
fi

# Normalize mode
case "${MODE}" in
    collect|c) MODE="collect" ;;
    distribute|d) MODE="distribute" ;;
    *) echo "[ERROR] -a option required: collect (c) or distribute (d)"; exit 1 ;;
esac

# -r/-R/-x/-D select what and where collect transfers; distribute has none of them
if [ "${MODE}" = "distribute" ] && { [ ${#RUN_IDS[@]} -gt 0 ] || [ ${#EXCLUDE_ARGS[@]} -gt 0 ] || [ -n "${COLLECT_DEST}" ]; }; then
    echo "[ERROR] -r / -R / -x / -D apply to collect only"
    exit 1
fi

# -D is resolved under the project root, so an absolute path would land outside
# the mount that both the host and the container agree on.
case "${COLLECT_DEST}" in
    /*) echo "[ERROR] -D must be relative to the project root, not absolute: ${COLLECT_DEST}"; exit 1 ;;
esac

# Find sync_hub server
SOURCE_SERVER=""
for _name in "${SERVER_LIST[@]}"; do
    declare -n _srv="SERVER_${_name}"
    if [ "${_srv[sync_hub]}" = "true" ]; then
        SOURCE_SERVER="$_name"
        break
    fi
done
unset -n _srv

if [ -z "${SOURCE_SERVER}" ]; then
    echo "[ERROR] No sync_hub server found in configuration"
    exit 1
fi

# Verify running on sync_hub (exact-match against every hostname IP)
if ! is_local_server "${SOURCE_SERVER}"; then
    declare -n src_srv="SERVER_${SOURCE_SERVER}"
    echo "[ERROR] This script must run on sync_hub (${SOURCE_SERVER}: ${src_srv[ip]})"
    unset -n src_srv
    exit 1
fi

declare -n src_srv="SERVER_${SOURCE_SERVER}"
LOCAL_VOL="${src_srv[source_mnt_path]}"
unset -n src_srv

# Get base docker target_mnt_path
declare -n _base_img="DOCKER_base"
DOCKER_VOL="${_base_img[target_mnt_path]}"
unset -n _base_img


# Ensure local base container is running
ensure_base "${SOURCE_SERVER}" || exit 1

# Verify project exists on sync_hub
if ! docker exec ${BASE_CONTAINER} test -d "${DOCKER_VOL}/${TARGET_PROJECT}"; then
    echo "[ERROR] project '${TARGET_PROJECT}' not found on sync_hub (${DOCKER_VOL}/${TARGET_PROJECT})"
    exit 1
fi

# ============================================
#  Collect: remote save → local save
# ============================================
_collect_server() {
    local name="$1"
    declare -n srv="SERVER_${name}"

    local user="${srv[ssh_user]}"
    local ip="${srv[ip]}"
    local remote_vol="${srv[source_mnt_path]}"
    local ssh_opts=$(build_ssh_opts "$name")

    echo "[${name}] ${ip}:${srv[port]}"

    # Any per-project error makes the whole server fail, so the caller's `wait`
    # sees it. Printing an error and still returning 0 is what let a failed
    # transfer report "completed successfully".
    local _rc=0
    local _probe_rc

    # Ensure remote base container is running. rc 2 (not 1) so the caller can tell
    # "this server was never inspected" from "a transfer failed".
    ensure_base "${name}" || { unset -n srv; return 2; }

    for proj in ${srv[git_available_list]}; do
        if [ -n "${TARGET_PROJECT}" ] && [ "${proj}" != "${TARGET_PROJECT}" ]; then
            continue
        fi

        # Verify project exists on remote
        if ! ssh ${ssh_opts} ${user}@${ip} "docker exec ${BASE_CONTAINER} test -d ${DOCKER_VOL}/${proj}"; then
            echo "  [${name}/${proj}] ERROR: project not found on remote, skipped"
            # Under -t all this server is simply not a source, which is normal for
            # a fan-out. Only an explicitly targeted server missing the project
            # means the transfer that was actually asked for cannot happen.
            [ "${TARGET_SERVER}" != "all" ] && _rc=1
            continue
        fi

        # raw training output now lives ABOVE the repo under artifacts/runs/{proj}
        # (sibling of the project dir), not in-repo outputs/save (2026-06-08 restructure).
        local remote_save_docker="${DOCKER_VOL}/artifacts/runs/${proj}"
        # -D lands the collected run dirs somewhere else under the project root
        # (e.g. outputs/models/pretraining/seed0/xferqoe), which is what the
        # promotion targets need; without it the default run store is used.
        local local_save_docker="${DOCKER_VOL}/artifacts/runs/${proj}"
        [ -n "${COLLECT_DEST}" ] && local_save_docker="${DOCKER_VOL}/${proj}/${COLLECT_DEST}"
        local local_staging_docker="${DOCKER_VOL}/artifacts/runs_staging/${proj}_${name}"
        local remote_save_host="${remote_vol}/artifacts/runs/${proj}"
        local local_staging_host="${LOCAL_VOL}/artifacts/runs_staging/${proj}_${name}"

        # Check if remote save has files. The probe's rc is checked separately so
        # an unreachable server cannot masquerade as an empty run store.
        local has_files
        has_files=$(ssh ${ssh_opts} ${user}@${ip} "docker exec ${BASE_CONTAINER} bash -c 'ls -A ${remote_save_docker}/ 2>/dev/null | head -1'")
        _probe_rc=$?
        if [ ${_probe_rc} -ne 0 ]; then
            echo "  [${name}/${proj}] ERROR: run-store probe failed (rc=${_probe_rc})"
            _rc=1
            continue
        fi
        if [ -z "${has_files}" ]; then
            echo "  [${name}/${proj}] save empty, skipped"
            continue
        fi

        # Selective collect: keep only the requested ids that actually exist here.
        # A run_id lives on exactly one server, so the same list is passed to every
        # server and each transfers its own subset instead of erroring on the rest.
        local -a present_ids=()
        if [ ${#RUN_IDS[@]} -gt 0 ]; then
            local existing
            # trailing `exit 0` because the loop's last `[ -d ]` returns 1 when the
            # final id is absent, which would otherwise read as a probe failure
            existing=$(ssh ${ssh_opts} ${user}@${ip} "docker exec ${BASE_CONTAINER} bash -c 'cd ${remote_save_docker} || exit 9; for d in ${RUN_IDS[*]}; do [ -d \"\$d\" ] && echo \"\$d\"; done; exit 0'")
            _probe_rc=$?
            if [ ${_probe_rc} -ne 0 ]; then
                echo "  [${name}/${proj}] ERROR: run_id probe failed (rc=${_probe_rc})"
                _rc=1
                continue
            fi
            [ -n "${existing}" ] && mapfile -t present_ids <<< "${existing}"
            if [ ${#present_ids[@]} -eq 0 ]; then
                echo "  [${name}/${proj}] none of the ${#RUN_IDS[@]} requested run_id(s) here, skipped"
                continue
            fi
            echo "  [${name}/${proj}] collecting ${#present_ids[@]}/${#RUN_IDS[@]} requested run_id(s)..."
        else
            echo "  [${name}/${proj}] collecting..."
        fi

        # Prepare local directories via docker (root permissions)
        # chown to host user so host-level rsync can write
        local host_uid; host_uid=$(id -u)
        local host_gid; host_gid=$(id -g)
        # chown the destination's parent too: with -D the dest is created fresh
        # under the repo and rsync writes at host level, so a root-owned parent
        # blocks the very first collect into a new topic dir.
        local runs_docker="${DOCKER_VOL}/artifacts/runs"
        local dest_parent; dest_parent=$(dirname "${local_save_docker}")
        docker exec ${BASE_CONTAINER} bash -c "mkdir -p ${runs_docker} ${local_staging_docker} ${local_save_docker} && chown ${host_uid}:${host_gid} ${runs_docker} ${dest_parent} ${local_staging_docker} ${local_save_docker}"

        # rsync from remote to local staging (host level).
        # --files-from turns off recursion, so -r brings it back for the named dirs.
        local rc
        local -a dry=(); [ "${DRY_RUN}" = true ] && dry=(--dry-run -v)
        if [ ${#present_ids[@]} -gt 0 ]; then
            printf '%s\n' "${present_ids[@]}" | rsync -az -r --omit-dir-times "${dry[@]}" "${EXCLUDE_ARGS[@]}" \
                --files-from=- -e "ssh ${ssh_opts}" "${user}@${ip}:${remote_save_host}/" "${local_staging_host}/"
            rc=$?
        else
            rsync -az --omit-dir-times "${dry[@]}" "${EXCLUDE_ARGS[@]}" -e "ssh ${ssh_opts}" "${user}@${ip}:${remote_save_host}/" "${local_staging_host}/"
            rc=$?
        fi

        if [ "${DRY_RUN}" = true ]; then
            echo "  [${name}/${proj}] dry run — nothing moved"
            docker exec ${BASE_CONTAINER} rm -rf "${local_staging_docker}"
        elif [ ${rc} -eq 0 ]; then
            # Read the run dirs that actually arrived, before the finalize move
            # empties staging. Reading staging rather than the requested list is
            # what makes the provenance report work with no -r/-R at all, and it
            # reports what landed instead of what was asked for.
            local -a landed_ids=()
            mapfile -t landed_ids < <(docker exec ${BASE_CONTAINER} bash -c "shopt -s nullglob; cd ${local_staging_docker} || exit 0; for d in */; do echo \"\${d%/}\"; done")
            # Finalize: staging → save. rm is CHAINED on the mv so a failed move
            # never deletes the freshly collected files; nullglob covers empty staging.
            if docker exec ${BASE_CONTAINER} bash -c "shopt -s dotglob nullglob; _f=(${local_staging_docker}/*); [ \${#_f[@]} -eq 0 ] || mv -f \"\${_f[@]}\" ${local_save_docker}/ && rm -rf ${local_staging_docker}"; then
                echo "  [${name}/${proj}] done"
                # Provenance for the caller's summary: one file per server, so the
                # parallel workers never append to the same file.
                local _pid
                for _pid in "${landed_ids[@]}"; do
                    printf '%s\t%s\t%s\n' "${_pid}" "${name}" "${proj}" >> "${LOG_DIR}/${name}.found"
                done
            else
                echo "  [${name}/${proj}] ERROR: finalize move failed — collected files kept in ${local_staging_host}"
                _rc=1
            fi
        else
            echo "  [${name}/${proj}] ERROR: rsync failed (rc=${rc}), remote files preserved"
            docker exec ${BASE_CONTAINER} rm -rf "${local_staging_docker}"
            _rc=1
        fi
    done
    unset -n srv
    return ${_rc}
}

# ============================================
#  Distribute: local models → remote models
# ============================================
_distribute_server() {
    local name="$1"
    declare -n srv="SERVER_${name}"

    local user="${srv[ssh_user]}"
    local ip="${srv[ip]}"
    local remote_vol="${srv[source_mnt_path]}"
    local ssh_opts=$(build_ssh_opts "$name")

    echo "[${name}] ${ip}:${srv[port]}"

    # Any per-project error makes the whole server fail, so the caller's `wait`
    # sees it. Printing an error and still returning 0 is what let a failed
    # transfer report "completed successfully".
    local _rc=0
    local _probe_rc

    # Ensure remote base container is running. rc 2 (not 1) so the caller can tell
    # "this server was never inspected" from "a transfer failed".
    ensure_base "${name}" || { unset -n srv; return 2; }

    for proj in ${srv[git_available_list]}; do
        if [ -n "${TARGET_PROJECT}" ] && [ "${proj}" != "${TARGET_PROJECT}" ]; then
            continue
        fi

        # Verify project exists on remote
        if ! ssh ${ssh_opts} ${user}@${ip} "docker exec ${BASE_CONTAINER} test -d ${DOCKER_VOL}/${proj}"; then
            echo "  [${name}/${proj}] ERROR: project not found on remote, skipped"
            # Under -t all this server is simply not a source, which is normal for
            # a fan-out. Only an explicitly targeted server missing the project
            # means the transfer that was actually asked for cannot happen.
            [ "${TARGET_SERVER}" != "all" ] && _rc=1
            continue
        fi

        local local_model_docker="${DOCKER_VOL}/${proj}/outputs/models"
        local remote_model_docker="${DOCKER_VOL}/${proj}/outputs/models"
        local remote_staging_docker="${DOCKER_VOL}/${proj}/outputs/models_staging"
        local local_model_host="${LOCAL_VOL}/${proj}/outputs/models"
        local remote_staging_host="${remote_vol}/${proj}/outputs/models_staging"

        # Check if local models has files
        local has_files
        has_files=$(docker exec ${BASE_CONTAINER} bash -c "ls -A ${local_model_docker}/ 2>/dev/null | head -1")
        _probe_rc=$?
        if [ ${_probe_rc} -ne 0 ]; then
            echo "  [${name}/${proj}] ERROR: local model-store probe failed (rc=${_probe_rc})"
            _rc=1
            continue
        fi
        if [ -z "${has_files}" ]; then
            echo "  [${name}/${proj}] models empty, skipped"
            continue
        fi

        echo "  [${name}/${proj}] distributing..."

        # If force, clear remote models
        if [ "${FORCE}" = true ]; then
            ssh ${ssh_opts} ${user}@${ip} "docker exec ${BASE_CONTAINER} bash -c 'rm -rf ${remote_model_docker}/*'" 2>/dev/null
            echo "  [${name}/${proj}] cleared remote models"
        fi

        # Prepare remote directories via docker
        # Get remote host UID and chown so host-level rsync can write
        local remote_uid
        remote_uid=$(ssh ${ssh_opts} ${user}@${ip} "id -u" 2>/dev/null)
        local remote_gid
        remote_gid=$(ssh ${ssh_opts} ${user}@${ip} "id -g" 2>/dev/null)
        local remote_outputs_docker="${DOCKER_VOL}/${proj}/outputs"
        ssh ${ssh_opts} ${user}@${ip} "docker exec ${BASE_CONTAINER} bash -c 'mkdir -p ${remote_staging_docker} ${remote_model_docker} && chown ${remote_uid}:${remote_gid} ${remote_outputs_docker} ${remote_staging_docker} ${remote_model_docker}'" 2>/dev/null

        # rsync from local to remote staging (host level)
        rsync -az --omit-dir-times -e "ssh ${ssh_opts}" "${local_model_host}/" "${user}@${ip}:${remote_staging_host}/"

        if [ $? -eq 0 ]; then
            # Finalize: staging → models. rm is CHAINED on the mv so a failed move
            # never deletes the freshly synced files; nullglob covers empty staging.
            if ssh ${ssh_opts} ${user}@${ip} "docker exec ${BASE_CONTAINER} bash -c 'shopt -s dotglob nullglob; _f=(${remote_staging_docker}/*); [ \${#_f[@]} -eq 0 ] || mv -f \"\${_f[@]}\" ${remote_model_docker}/ && rm -rf ${remote_staging_docker}'"; then
                echo "  [${name}/${proj}] done"
            else
                echo "  [${name}/${proj}] ERROR: finalize move failed — synced files kept in ${remote_staging_host}"
                _rc=1
            fi
        else
            echo "  [${name}/${proj}] ERROR: rsync failed"
            ssh ${ssh_opts} ${user}@${ip} "docker exec ${BASE_CONTAINER} rm -rf ${remote_staging_docker}" 2>/dev/null
            _rc=1
        fi
    done
    unset -n srv
    return ${_rc}
}

# ============================================
#  Main — parallel execution per server
# ============================================
LOG_DIR=$(mktemp -d)
pids=()
names=()

for name in "${SERVER_LIST[@]}"; do
    declare -n srv="SERVER_${name}"

    if [ "${TARGET_SERVER}" = "all" ]; then
        [ "${srv[server_active_status]}" != "true" ] && continue
    else
        [ "$name" != "${TARGET_SERVER}" ] && continue
    fi

    # Skip sync_hub and non-remote servers
    [ "${srv[sync_hub]}" = "true" ] && continue
    [ "${srv[server_remote]}" != "true" ] && continue

    if [ "${MODE}" = "collect" ]; then
        _collect_server "$name" > "${LOG_DIR}/${name}.log" 2>&1 &
    else
        _distribute_server "$name" > "${LOG_DIR}/${name}.log" 2>&1 &
    fi
    pids+=($!)
    names+=("$name")

    unset -n srv
done

# No peer at all is a targeting mistake, not an empty result. Without this the
# run reads as "none of the requested run_ids exist anywhere", which is a
# confident wrong answer — nothing was ever looked at.
if [ ${#pids[@]} -eq 0 ]; then
    rm -rf "${LOG_DIR}"
    echo "[artifact_sync] no server matched -t '${TARGET_SERVER}' — nothing was inspected"
    echo "  the sync_hub (${SOURCE_SERVER}) and non-remote servers are never a ${MODE} peer"
    exit 1
fi

# Wait for all parallel jobs and print results. rc 2 = the server was never
# inspected (no base container); it is reported separately from a transfer that
# actually failed, so that one powered-off box in a fan-out does not make every
# run exit non-zero — an always-1 exit code is ignored as fast as an always-0 one.
has_failure=false
_not_inspected=""
for i in "${!pids[@]}"; do
    wait ${pids[$i]}
    _wrc=$?
    if [ ${_wrc} -eq 2 ]; then
        _not_inspected="${_not_inspected} ${names[$i]}"
    elif [ ${_wrc} -ne 0 ]; then
        has_failure=true
    fi
    echo "=================================="
    cat "${LOG_DIR}/${names[$i]}.log"
    echo ""
done

# run_id → source server, unioned across the parallel workers. A run_id is
# opaque, so this is the only place the mapping exists; the runs_map that every
# table needs is built from it.
_all_found="${LOG_DIR}/_all.found"
cat "${LOG_DIR}"/*.found > "${_all_found}" 2>/dev/null
if [ -s "${_all_found}" ]; then
    echo "[artifact_sync] collected run_id → source server"
    sort "${_all_found}" | awk -F'\t' '{printf "    %-34s %-8s %s\n", $1, $2, $3}'
    echo ""
fi

# Requested ids that no server had. Without this a collect that transferred
# nothing at all still reported success — the fan-out skips every server with
# "none of the requested run_id(s) here", which alone is a normal message.
_missing=""
if [ ${#RUN_IDS[@]} -gt 0 ]; then
    for _id in "${RUN_IDS[@]}"; do
        cut -f1 "${_all_found}" 2>/dev/null | grep -qxF "${_id}" || _missing="${_missing} ${_id}"
    done
fi

rm -rf "${LOG_DIR}"

if [ -n "${_missing}" ]; then
    echo "[artifact_sync] NOT FOUND on any inspected server:${_missing}"
fi
if [ -n "${_not_inspected}" ]; then
    echo "[artifact_sync] [WARN] not inspected (base container unavailable):${_not_inspected}"
    echo "  Their stores were never read — re-run once they are up if something you expected is missing."
fi

if [ "${has_failure}" = true ]; then
    echo "[artifact_sync] FAILED — see the per-server logs above"
    exit 1
fi
# A missing id is only conclusive when every server was actually inspected;
# with a box down it is unknown, so it is reported without failing the run.
if [ -n "${_missing}" ] && [ -z "${_not_inspected}" ]; then
    echo "[artifact_sync] FAILED — ${#RUN_IDS[@]} run_id(s) requested, some exist nowhere"
    exit 1
fi
if [ -n "${_missing}" ] || [ -n "${_not_inspected}" ]; then
    echo "[artifact_sync] completed with gaps — see the lines above"
    exit 0
fi
echo "[artifact_sync] completed successfully"
exit 0
