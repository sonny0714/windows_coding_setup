#!/bin/bash
# ============================================
#  Docker Run — remote docker setup
#
#  Usage:
#    ./docker.sh -i <image> -t all              — start missing on all eligible servers
#    ./docker.sh -i <image> -t all -f           — force restart on non-push servers
#    ./docker.sh -i <image> -t <server>         — start missing on specific server
#    ./docker.sh -i <image> -t <server> -f      — force restart on specific server
#
#  Options:
#    -i <image>   target docker image — required
#                   must be in the target server's docker_available_list
#                   (defaults already merged in by yaml_to_bash.py)
#    -t <server>  target server — required ("all" = common rule)
#    -f           force: stop containers, pull image, restart all containers
#                 without -f: only pull/start containers that are not running
#                 with -t all: also drops servers with allow_push=true (protective)
#    -h           show help
#
#  Target rules (see utils.sh::resolve_target_servers):
#    -t all       → active O, common remote rule
#    -t all -f    → active O, common remote rule, allow_push X (protective)
#    -t <server>  → active O (single server)
#    -t <server> -f → active O (single server, no allow_push filter)
#
#  Execution order (per server):
#    Phase 1: stop/rm target containers (only with -f, or for missing ones otherwise)
#    Phase 2: pull image (only with -f, or if any container needs creation)
#    Phase 3: run all target containers
#    On failure → warn with reboot recommendation
#
#  Container naming (per-user, by name pattern):
#    base image  → "base_{PROJECT_USER}"               (CPU-only, no GPU)
#    other image → "{name}_test_{PROJECT_USER}"         (allow_push only, GPU 0)
#                  "{name}_{gpu_id}_{PROJECT_USER}"     (per-GPU, e.g. netai_0_sonny)
# ============================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
eval "$(python3 "${SCRIPT_DIR}/exec.py" "$(cd "${SCRIPT_DIR}/../../../.." && pwd)/md_files/worklog/users.yaml" "sonny")"
source "${SCRIPT_DIR}/utils.sh"

_show_help() { sed -n '2,/^# ====.*$/p' "$0" | sed 's/^# \?//'; exit 0; }

# Parse options
TARGET_SERVER=""
TARGET_IMAGE=""
FORCE=false
SHOW_HELP=false

while getopts "t:i:fh" opt; do
    case $opt in
        t) TARGET_SERVER="$OPTARG" ;;
        i) TARGET_IMAGE="$OPTARG" ;;
        f) FORCE=true ;;
        h) SHOW_HELP=true ;;
        *) echo "Usage: $0 -i <image> -t <server|all> [-f] [-h]"; exit 1 ;;
    esac
done

[ "${SHOW_HELP}" = true ] && _show_help

# Validate required options
if [ -z "${TARGET_IMAGE}" ]; then
    echo "[ERROR] -i option required: specify a docker image"
    exit 1
fi

if [ -z "${TARGET_SERVER}" ]; then
    echo "[ERROR] -t option required: specify a server or 'all'"
    exit 1
fi

# Resolve targets via common rule. -f tightens the filter to non-push servers
# only when -t is "all" (single-server -f respects the user's explicit choice).
if [ "${TARGET_SERVER}" = "all" ] && [ "${FORCE}" = true ]; then
    _targets=$(resolve_target_servers all no_push) || exit 1
elif [ "${TARGET_SERVER}" = "all" ]; then
    _targets=$(resolve_target_servers all) || exit 1
else
    _targets=$(resolve_target_servers "${TARGET_SERVER}") || exit 1
fi

if [ -z "${_targets}" ]; then
    echo "[INFO] no eligible target servers"
    exit 0
fi

# Read targets from fd 3 so the inner ssh call cannot consume the loop's
# stdin (same fix as exec/git.sh).
while IFS= read -r name <&3; do
    [ -z "${name}" ] && continue
    declare -n srv="SERVER_${name}"

    # Image must be in this server's combined available list
    if ! in_docker_available "${name}" "${TARGET_IMAGE}"; then
        echo "[SKIP] ${name} — '${TARGET_IMAGE}' not in docker available list"
        unset -n srv
        continue
    fi
    [ -z "${srv[source_mnt_path]}" ] && { unset -n srv; continue; }

    echo "=================================="
    echo "[${name}] ${srv[ip]}:${srv[port]}"
    echo "=================================="

    port_opt=""
    [ "${srv[port]}" != "22" ] && [ -n "${srv[port]}" ] && port_opt="-p ${srv[port]}"

    key_opt=""
    [ -n "${srv[ssh_key]}" ] && key_opt="-i ${srv[ssh_key]}"

    dock_src="${srv[source_mnt_path]}"
    # docker_network: empty → default bridge. Non-empty → `--network <val>`,
    # typically "host" for containers running TCP/IP socket programs that
    # need direct host network access (no NAT / no port mapping).
    net_opt=""
    [ -n "${srv[docker_network]}" ] && net_opt="--network ${srv[docker_network]}"

    # Build 3-phase remote commands
    stop_cmds=""
    pull_cmds=""
    run_cmds=""

    suffix="_${PROJECT_USER}"
    declare -n img="DOCKER_${TARGET_IMAGE}"
    image="${img[image]}"
    vol="-v ${dock_src}:${img[target_mnt_path]}"
    opts="$(echo "${img[options]}" | sed 's/-it//; s/  */ /g; s/^ //; s/ $//')"
    image_var="need_pull_${image//[^a-zA-Z0-9]/_}"

    # Collect containers for this image (per-user naming)
    containers=()
    if [ "${TARGET_IMAGE}" = "base" ]; then
        containers+=("base${suffix}|docker run -d ${net_opt} ${vol} ${opts} --name base${suffix} ${image} sleep infinity")
    else
        if [ -z "${srv[gpu_available_list]}" ]; then
            unset -n img srv
            echo ""
            continue
        fi
        # test container (GPU 0) — allow_push only
        if [ "${srv[allow_push]}" = "true" ]; then
            containers+=("${TARGET_IMAGE}_test${suffix}|docker run -d ${net_opt} --gpus device=0 ${vol} ${opts} --name ${TARGET_IMAGE}_test${suffix} ${image} sleep infinity")
        fi
        # per-GPU containers
        for gpu in ${srv[gpu_available_list]}; do
            containers+=("${TARGET_IMAGE}_${gpu}${suffix}|docker run -d ${net_opt} --gpus device=${gpu} ${vol} ${opts} --name ${TARGET_IMAGE}_${gpu}${suffix} ${image} sleep infinity")
        done
    fi

    for entry in "${containers[@]}"; do
        cname="${entry%%|*}"
        run_cmd="${entry#*|}"
        cname_var="need_${cname//[^a-zA-Z0-9]/_}"

        if [ "${FORCE}" = true ]; then
            stop_cmds="${stop_cmds}echo '  [stop] ${cname}'; docker stop ${cname} 2>/dev/null; echo '  [rm] ${cname}'; docker rm -f ${cname} 2>/dev/null; "
            run_cmds="${run_cmds}echo '  [run] ${cname}'; ${run_cmd} || has_failure=true; "
        else
            stop_cmds="${stop_cmds}if docker ps -a --format '{{.Names}}' | grep -qx '${cname}'; then echo '  [ok] ${cname}'; else ${cname_var}=true; ${image_var}=true; echo '  [new] ${cname}'; fi; "
            run_cmds="${run_cmds}if [ \"\${${cname_var}}\" = true ]; then echo '  [run] ${cname}'; ${run_cmd} || has_failure=true; fi; "
        fi
    done

    # Pull image once
    if [ "${FORCE}" = true ]; then
        pull_cmds="${pull_cmds}echo '  [pull] ${image}'; docker pull ${image}; "
    else
        pull_cmds="${pull_cmds}if [ \"\${${image_var}}\" = true ]; then echo '  [pull] ${image}'; docker pull ${image}; fi; "
    fi

    unset -n img

    # Combine: phase1 (stop) → phase2 (pull) → phase3 (run) → failure check
    remote_cmds="has_failure=false; ${stop_cmds}${pull_cmds}${run_cmds}"
    remote_cmds="${remote_cmds}if [ \"\${has_failure}\" = true ]; then echo '  [WARNING] docker run failed on ${name}, reboot recommended: sudo reboot now'; fi; "

    # bash if current machine, otherwise SSH. -t is omitted (no tty needed
    # for non-interactive docker commands), and stdin is redirected from
    # /dev/null as a belt-and-braces measure on top of the fd 3 trick above.
    if is_local_server "${name}"; then
        bash -c "${remote_cmds}"
    else
        ssh ${port_opt} ${key_opt} ${srv[ssh_user]}@${srv[ip]} "${remote_cmds}" < /dev/null
    fi
    unset -n srv
    echo ""
done 3<<< "${_targets}"
