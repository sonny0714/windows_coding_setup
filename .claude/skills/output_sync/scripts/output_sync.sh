#!/bin/bash
# ============================================
#  Output Sync — collect/distribute experiment outputs between servers
#
#  Usage:
#    ./output_sync.sh -a collect -p <project> -t all       — collect save from all active servers
#    ./output_sync.sh -a c -p <project> -t all             — short for collect
#    ./output_sync.sh -a distribute -p <project> -t all    — distribute load to all active servers
#    ./output_sync.sh -a d -p <project> -t all             — short for distribute
#    ./output_sync.sh -a c -p <project> -t <server>        — collect from specific server
#    ./output_sync.sh -a d -p <project> -t <server> -f     — distribute to server, clear load first
#
#  Options:
#    -a <mode>    collect (c) or distribute (d) — required
#    -p <project> target project — required
#    -t <server>  target server — required ("all" = all server_active_status=true servers)
#    -f           distribute only: clear remote load/ before transfer
#    -h           show help
#
#  Collect (remote → sync_hub):
#    Per server (parallel):
#      1. rsync remote:{project}/outputs/save/ → local save_staging_{server}/
#      2. mv staging files → save/
#      3. rm staging
#
#  Distribute (sync_hub → remote):
#    Per server (parallel):
#      1. (-f) rm remote load/*
#      2. rsync local:{project}/outputs/load/ → remote load_staging/
#      3. mv staging files → load/
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
eval "$(python3 "${SCRIPT_DIR}/exec.py" "$(cd "${SCRIPT_DIR}/../../../.." && pwd)/md_files/worklog/users.yaml" "sonny")"
source "${SCRIPT_DIR}/utils.sh"

_show_help() { sed -n '2,/^# ====.*$/p' "$0" | sed 's/^# \?//'; exit 0; }

# Parse options
MODE=""
TARGET_SERVER=""
TARGET_PROJECT=""
FORCE=false
SHOW_HELP=false

while getopts "a:t:p:fh" opt; do
    case $opt in
        a) MODE="$OPTARG" ;;
        t) TARGET_SERVER="$OPTARG" ;;
        p) TARGET_PROJECT="$OPTARG" ;;
        f) FORCE=true ;;
        h) SHOW_HELP=true ;;
        *) echo "Usage: $0 -a <collect|distribute> -t <server|all> -p <project> [-f] [-h]"; exit 1 ;;
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
ensure_base "${SOURCE_SERVER}" "${SCRIPT_DIR}" || exit 1

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

    # Ensure remote base container is running
    ensure_base "${name}" "${SCRIPT_DIR}" || { unset -n srv; return 1; }

    for proj in ${srv[git_available_list]}; do
        if [ -n "${TARGET_PROJECT}" ] && [ "${proj}" != "${TARGET_PROJECT}" ]; then
            continue
        fi

        # Verify project exists on remote
        if ! ssh ${ssh_opts} ${user}@${ip} "docker exec ${BASE_CONTAINER} test -d ${DOCKER_VOL}/${proj}" 2>/dev/null; then
            echo "  [${name}/${proj}] ERROR: project not found on remote, skipped"
            continue
        fi

        local remote_save_docker="${DOCKER_VOL}/${proj}/outputs/save"
        local local_save_docker="${DOCKER_VOL}/${proj}/outputs/save"
        local local_staging_docker="${DOCKER_VOL}/${proj}/outputs/save_staging_${name}"
        local remote_save_host="${remote_vol}/${proj}/outputs/save"
        local local_staging_host="${LOCAL_VOL}/${proj}/outputs/save_staging_${name}"

        # Check if remote save has files
        local has_files
        has_files=$(ssh ${ssh_opts} ${user}@${ip} "docker exec ${BASE_CONTAINER} bash -c 'ls -A ${remote_save_docker}/ 2>/dev/null | head -1'" 2>/dev/null)
        if [ -z "${has_files}" ]; then
            echo "  [${name}/${proj}] save empty, skipped"
            continue
        fi

        echo "  [${name}/${proj}] collecting..."

        # Prepare local directories via docker (root permissions)
        # chown to host user so host-level rsync can write
        local host_uid; host_uid=$(id -u)
        local host_gid; host_gid=$(id -g)
        local outputs_docker="${DOCKER_VOL}/${proj}/outputs"
        docker exec ${BASE_CONTAINER} bash -c "mkdir -p ${local_staging_docker} ${local_save_docker} && chown ${host_uid}:${host_gid} ${outputs_docker} ${local_staging_docker} ${local_save_docker}"

        # rsync from remote to local staging (host level)
        rsync -az --omit-dir-times -e "ssh ${ssh_opts}" "${user}@${ip}:${remote_save_host}/" "${local_staging_host}/"

        if [ $? -eq 0 ]; then
            # mv staging files → save, then rm staging dir
            docker exec ${BASE_CONTAINER} bash -c "mv -f ${local_staging_docker}/* ${local_staging_docker}/.[!.]* ${local_save_docker}/ 2>/dev/null; rm -rf ${local_staging_docker}"
            echo "  [${name}/${proj}] done"
        else
            echo "  [${name}/${proj}] ERROR: rsync failed, remote files preserved"
            docker exec ${BASE_CONTAINER} rm -rf "${local_staging_docker}"
        fi
    done
    unset -n srv
}

# ============================================
#  Distribute: local load → remote load
# ============================================
_distribute_server() {
    local name="$1"
    declare -n srv="SERVER_${name}"

    local user="${srv[ssh_user]}"
    local ip="${srv[ip]}"
    local remote_vol="${srv[source_mnt_path]}"
    local ssh_opts=$(build_ssh_opts "$name")

    echo "[${name}] ${ip}:${srv[port]}"

    # Ensure remote base container is running
    ensure_base "${name}" "${SCRIPT_DIR}" || { unset -n srv; return 1; }

    for proj in ${srv[git_available_list]}; do
        if [ -n "${TARGET_PROJECT}" ] && [ "${proj}" != "${TARGET_PROJECT}" ]; then
            continue
        fi

        # Verify project exists on remote
        if ! ssh ${ssh_opts} ${user}@${ip} "docker exec ${BASE_CONTAINER} test -d ${DOCKER_VOL}/${proj}" 2>/dev/null; then
            echo "  [${name}/${proj}] ERROR: project not found on remote, skipped"
            continue
        fi

        local local_load_docker="${DOCKER_VOL}/${proj}/outputs/load"
        local remote_load_docker="${DOCKER_VOL}/${proj}/outputs/load"
        local remote_staging_docker="${DOCKER_VOL}/${proj}/outputs/load_staging"
        local local_load_host="${LOCAL_VOL}/${proj}/outputs/load"
        local remote_staging_host="${remote_vol}/${proj}/outputs/load_staging"

        # Check if local load has files
        local has_files
        has_files=$(docker exec ${BASE_CONTAINER} bash -c "ls -A ${local_load_docker}/ 2>/dev/null | head -1")
        if [ -z "${has_files}" ]; then
            echo "  [${name}/${proj}] load empty, skipped"
            continue
        fi

        echo "  [${name}/${proj}] distributing..."

        # If force, clear remote load
        if [ "${FORCE}" = true ]; then
            ssh ${ssh_opts} ${user}@${ip} "docker exec ${BASE_CONTAINER} bash -c 'rm -rf ${remote_load_docker}/*'" 2>/dev/null
            echo "  [${name}/${proj}] cleared remote load"
        fi

        # Prepare remote directories via docker
        # Get remote host UID and chown so host-level rsync can write
        local remote_uid
        remote_uid=$(ssh ${ssh_opts} ${user}@${ip} "id -u" 2>/dev/null)
        local remote_gid
        remote_gid=$(ssh ${ssh_opts} ${user}@${ip} "id -g" 2>/dev/null)
        local remote_outputs_docker="${DOCKER_VOL}/${proj}/outputs"
        ssh ${ssh_opts} ${user}@${ip} "docker exec ${BASE_CONTAINER} bash -c 'mkdir -p ${remote_staging_docker} ${remote_load_docker} && chown ${remote_uid}:${remote_gid} ${remote_outputs_docker} ${remote_staging_docker} ${remote_load_docker}'" 2>/dev/null

        # rsync from local to remote staging (host level)
        rsync -az --omit-dir-times -e "ssh ${ssh_opts}" "${local_load_host}/" "${user}@${ip}:${remote_staging_host}/"

        if [ $? -eq 0 ]; then
            # mv staging files → load, then rm staging dir
            ssh ${ssh_opts} ${user}@${ip} "docker exec ${BASE_CONTAINER} bash -c 'mv -f ${remote_staging_docker}/* ${remote_staging_docker}/.[!.]* ${remote_load_docker}/ 2>/dev/null; rm -rf ${remote_staging_docker}'"
            echo "  [${name}/${proj}] done"
        else
            echo "  [${name}/${proj}] ERROR: rsync failed"
            ssh ${ssh_opts} ${user}@${ip} "docker exec ${BASE_CONTAINER} rm -rf ${remote_staging_docker}" 2>/dev/null
        fi
    done
    unset -n srv
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

# Wait for all parallel jobs and print results
has_failure=false
for i in "${!pids[@]}"; do
    wait ${pids[$i]} || has_failure=true
    echo "=================================="
    cat "${LOG_DIR}/${names[$i]}.log"
    echo ""
done

rm -rf "${LOG_DIR}"

if [ "${has_failure}" = true ]; then
    echo "[output_sync] completed with errors"
else
    echo "[output_sync] completed successfully"
fi
