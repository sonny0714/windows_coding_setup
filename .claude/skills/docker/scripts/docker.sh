#!/bin/bash
# ============================================
#  Docker Run — remote docker setup
#
#  Usage:
#    ./docker.sh -i <image> -t all              — start missing on all eligible servers
#    ./docker.sh -i <image> -t all -f           — force restart on non-push servers
#    ./docker.sh -i <image> -t <server>         — start missing on specific server
#    ./docker.sh -i <image> -t <server> -f      — force restart on specific server
#    ./docker.sh -i <image> -t <server> -g <n>  — only that GPU's container
#    ./docker.sh -i <img> -t <srv> -g 0 -n b    — extra container beside {img}_0_*
#
#  Options:
#    -i <image>   target docker image — required
#                   must be in the target server's docker_available_list
#                   (defaults already merged in by yaml_to_bash.py)
#    -t <server>  target server — required ("all" = common rule)
#    -g <gpu_id>  restrict to ONE gpu — handles only "{image}_{gpu_id}_{PROJECT_USER}"
#                 and skips the _test container. Needs a single -t <server>
#                 (gpu ids are per-server) and a gpu in its gpu_available_list
#    -n <tag>     name tag appended to the gpu id → "{image}_{gpu_id}{tag}_{PROJECT_USER}"
#                 (-g 0 -n b → netai_0b_sonny), so a dedicated container can sit
#                 beside a busy one on the same gpu. Requires -g; [a-z0-9] only
#    -f           force: stop containers, pull image, restart all containers
#                 without -f: only pull/start containers that are not running
#                 with -t all: also drops push servers of any project (protective)
#    -h           show help
#
#  Target rules (see utils.sh::resolve_target_servers):
#    -t all       → active O, common remote rule
#    -t all -f    → active O, common remote rule, push servers X (protective,
#                   union over every project's git_server_allow_push)
#    -t <server>  → active O (single server)
#    -t <server> -f → active O (single server, no push filter)
#
#  Execution order (per server):
#    Phase 0: preflight — docker installed + daemon up, image has a build for the
#             server arch (docker_images.<img>.platforms). Missing → [SKIP].
#    Phase 1: stop/rm target containers (only with -f, or for missing ones otherwise)
#    Phase 2: pull image (only with -f, or if any container needs creation)
#    Phase 3: run all target containers
#    On failure → warn with reboot recommendation
#
#  Container naming (per-user, by name pattern):
#    base image  → "base_{PROJECT_USER}"               (CPU-only, no GPU)
#    other image → "{name}_test_{PROJECT_USER}"         (owning project's push servers only, GPU 0)
#                  "{name}_{gpu_id}_{PROJECT_USER}"     (per-GPU default, e.g. netai_0_sonny)
#  A GPU is NOT limited to one container — up to 4 may share a GPU; give each
#  extra one a distinct name (suffix the gpu_id, e.g. netai_0b_sonny).
# ============================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
eval "$(python3 "${SCRIPT_DIR}/exec.py" "$(cd "${SCRIPT_DIR}/../../../.." && pwd)/md_files/users/users.yaml" "sonny")"
source "${SCRIPT_DIR}/utils.sh"

_show_help() { sed -n '2,/^# ====.*$/p' "$0" | sed 's/^# \?//'; exit 0; }

# docker_arch / resolve_docker_image come from core/common/utils.sh — one image key can
# carry a per-platform tag (base:pi on the aarch64 Pis) while the container name
# stays {key}_{PROJECT_USER}.

# Parse options
TARGET_SERVER=""
TARGET_IMAGE=""
TARGET_GPU=""
TARGET_TAG=""
FORCE=false
SHOW_HELP=false

while getopts "t:i:g:n:fh" opt; do
    case $opt in
        t) TARGET_SERVER="$OPTARG" ;;
        i) TARGET_IMAGE="$OPTARG" ;;
        g) TARGET_GPU="$OPTARG" ;;
        n) TARGET_TAG="$OPTARG" ;;
        f) FORCE=true ;;
        h) SHOW_HELP=true ;;
        *) echo "Usage: $0 -i <image> -t <server|all> [-g <gpu_id>] [-n <tag>] [-f] [-h]"; exit 1 ;;
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

# -g / -n narrow the run down to a single container. A gpu id only means something
# on one server, so both require -t <server> rather than "all".
if [ -n "${TARGET_GPU}" ]; then
    if [ "${TARGET_SERVER}" = "all" ]; then
        echo "[ERROR] -g needs a single -t <server>: gpu ids are per-server"
        exit 1
    fi
    if [ "${TARGET_IMAGE}" = "base" ]; then
        echo "[ERROR] -g not valid for image 'base': it is CPU-only"
        exit 1
    fi
fi

if [ -n "${TARGET_TAG}" ]; then
    if [ -z "${TARGET_GPU}" ]; then
        echo "[ERROR] -n needs -g <gpu_id>: the tag names an extra container on that gpu"
        exit 1
    fi
    case "${TARGET_TAG}" in
        *[!a-z0-9]*) echo "[ERROR] -n tag must be [a-z0-9] only (got '${TARGET_TAG}')"; exit 1 ;;
    esac
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
# stdin (same fix as core/git/git.sh).
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

    print_target_banner "${name}"

    # Preflight: probe docker + arch in one round trip, before any pull/run.
    # An amd64-only image on aarch64 pulls without complaint and only dies at
    # `docker run` with "exec format error"; a missing docker CLI dies the same
    # way. Both used to land in the generic has_failure branch below, which
    # tells the user to reboot — wrong advice for both causes.
    _pf="$(run_on_server "${name}" 'if command -v docker >/dev/null 2>&1; then docker info >/dev/null 2>&1 && echo "docker=ok" || echo "docker=nodaemon"; else echo "docker=missing"; fi; echo "arch=$(uname -m)"; echo "cgroup=$(stat -fc %T /sys/fs/cgroup 2>/dev/null)"; echo "swapdev=$(tail -n +2 /proc/swaps 2>/dev/null | wc -l)"')"
    _pf_docker="$(echo "${_pf}" | sed -n 's/^docker=//p')"
    _pf_arch="$(docker_arch "$(echo "${_pf}" | sed -n 's/^arch=//p')")"
    # cgroup2fs = unified (v2), tmpfs = v1 hierarchy — decides swap_opt below.
    _pf_cgroup="$(echo "${_pf}" | sed -n 's/^cgroup=//p')"
    _pf_swapdev="$(echo "${_pf}" | sed -n 's/^swapdev=//p')"

    case "${_pf_docker}" in
        missing)
            echo "  [SKIP] ${name} — docker is not installed"
            echo "         install it, then re-run this command:"
            echo "           curl -fsSL https://get.docker.com | sh"
            echo "           sudo usermod -aG docker \$(id -un)   # then re-login"
            unset -n srv; echo ""; continue
            ;;
        nodaemon)
            echo "  [SKIP] ${name} — docker is installed but the daemon is unreachable"
            echo "         start it, or add yourself to the docker group:"
            echo "           sudo systemctl start docker"
            echo "           sudo usermod -aG docker \$(id -un)   # then re-login"
            unset -n srv; echo ""; continue
            ;;
        ok) ;;
        *)
            echo "  [SKIP] ${name} — could not probe docker (server unreachable?)"
            unset -n srv; echo ""; continue
            ;;
    esac

    resolve_docker_image "${TARGET_IMAGE}" "${_pf_arch}"
    if [ -z "${RESOLVED_IMAGE}" ]; then
        echo "  [SKIP] ${name} — '${TARGET_IMAGE}' has no ${_pf_arch} build"
        echo "         declared platforms : ${RESOLVED_PLATFORMS:-<none>}"
        echo "         server arch        : ${_pf_arch}"
        echo "         running it here would fail with 'exec format error'."
        echo "         to support it, publish a matching image and add it under"
        echo "         docker_images.${TARGET_IMAGE}.platforms.linux/${_pf_arch}"
        unset -n srv; echo ""; continue
    fi

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
    # Set by the arch preflight above, so a per-arch build (e.g. base:pi on the
    # aarch64 Pis) is what actually gets pulled and run here.
    image="${RESOLVED_IMAGE}"
    vol="-v ${dock_src}:${img[target_mnt_path]}"
    opts="$(echo "${RESOLVED_OPTIONS}" | sed 's/-it//; s/  */ /g; s/^ //; s/ $//')"
    # GPU images run training jobs whose DataLoaders use /dev/shm heavily.
    # Default container shm is 64 MB → DataLoader workers OOM ("Bus error").
    # Set shm-size per-server to ~90 % of host RAM so it scales with the box
    # (deep 128GB → ~115g, z3 64GB → ~57g). tmpfs is lazy-allocated, so this
    # is a ceiling, not a reservation. base image is CPU-only, skip.
    shm_opt=""
    if [ "${TARGET_IMAGE}" != "base" ]; then
        if is_local_server "${name}"; then
            mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
        else
            mem_kb=$(ssh ${port_opt} ${key_opt} ${srv[ssh_user]}@${srv[ip]} "awk '/^MemTotal:/ {print \$2}' /proc/meminfo" 2>/dev/null < /dev/null)
        fi
        if [ -n "${mem_kb}" ] && [ "${mem_kb}" -gt 0 ] 2>/dev/null; then
            shm_gb=$(( mem_kb * 9 / 10 / 1024 / 1024 ))
            [ "${shm_gb}" -lt 1 ] && shm_gb=1
            shm_opt="--shm-size=${shm_gb}g"
        else
            echo "  [WARN] could not detect host RAM, falling back to --shm-size=8g"
            shm_opt="--shm-size=8g"
        fi
    fi
    # Prevent this container from swapping its anonymous pages. --memory-swappiness=0
    # turns swap off for the container without a memory cap, so it never forces an
    # artificial OOM the way --memory-swap == --memory would (which would kill long
    # training runs on a DataLoader spike). Applied to every image incl. base.
    #
    # The knob only exists in cgroup v1. v2 replaced the swappiness ratio with
    # absolute limits (memory.swap.max), so docker discards the flag and warns
    # ("kernel does not support memory swappiness"). The split is per OS release
    # (Ubuntu 20.04 → v1, 22.04+ → v2), so detect it instead of always passing it.
    # An unreadable probe falls back to passing the flag = previous behaviour.
    swap_opt="--memory-swappiness=0"
    if [ "${_pf_cgroup}" = "cgroup2fs" ]; then
        swap_opt=""
        if [ "${_pf_swapdev:-0}" -gt 0 ] 2>/dev/null; then
            echo "  [WARN] cgroup v2 + ${_pf_swapdev} swap device(s): container swapping cannot be suppressed"
            echo "         a GPU server should carry no swap device — runs may be paged out"
        fi
    fi
    # Suppress .pyc generation for every process in the container (incl. later
    # docker exec sessions, which inherit the env set at run time). The GPU
    # image bakes this via Dockerfile ENV; the base image does not, so set it
    # here unconditionally to cover both.
    nopyc_opt="-e PYTHONDONTWRITEBYTECODE=1"
    # Inject the owning project's wandb creds (per-project WANDB_API_KEY_<proj> /
    # WANDB_ENTITY_<proj>) so runs authenticate without a per-container `wandb
    # login`, surviving recreation. Resolve TARGET_IMAGE → project via
    # PROJECT_DOCKER_<proj>. Empty creds → no injection (GPU containers only; base
    # is CPU-only and never logs to wandb).
    wandb_opt=""
    for _wproj in "${GIT_PROJECT_LIST[@]}"; do
        _wpd_var="PROJECT_DOCKER_${_wproj}"
        for _wimg in ${!_wpd_var:-}; do
            [ "${_wimg}" = "${TARGET_IMAGE}" ] || continue
            _wkey_var="WANDB_API_KEY_${_wproj}"; _went_var="WANDB_ENTITY_${_wproj}"
            [ -n "${!_wkey_var:-}" ] && wandb_opt="-e WANDB_API_KEY=${!_wkey_var}"
            [ -n "${!_went_var:-}" ] && wandb_opt="${wandb_opt} -e WANDB_ENTITY=${!_went_var}"
        done
    done
    image_var="need_pull_${image//[^a-zA-Z0-9]/_}"

    # Collect containers for this image (per-user naming)
    containers=()
    if [ "${TARGET_IMAGE}" = "base" ]; then
        containers+=("base${suffix}|docker run -d --init ${swap_opt} ${nopyc_opt} ${net_opt} ${vol} ${opts} --name base${suffix} ${image} sleep infinity")
    else
        if [ -z "${srv[gpu_available_list]}" ]; then
            unset -n img srv
            echo ""
            continue
        fi
        # -g narrows this run to one gpu; the _test container is not part of that.
        gpu_list="${srv[gpu_available_list]}"
        if [ -n "${TARGET_GPU}" ]; then
            if ! printf '%s\n' ${srv[gpu_available_list]} | grep -qx -- "${TARGET_GPU}"; then
                echo "  [SKIP] gpu ${TARGET_GPU} not in gpu_available_list (${srv[gpu_available_list]})"
                unset -n img srv
                echo ""
                continue
            fi
            gpu_list="${TARGET_GPU}"
        fi
        # test container (GPU 0) — push servers of the image's owning project(s)
        if is_push_server_for_image "${name}" "${TARGET_IMAGE}" && [ -z "${TARGET_GPU}" ]; then
            containers+=("${TARGET_IMAGE}_test${suffix}|docker run -d --init ${swap_opt} ${nopyc_opt} ${wandb_opt} ${net_opt} --gpus device=0 ${shm_opt} ${vol} ${opts} --name ${TARGET_IMAGE}_test${suffix} ${image} sleep infinity")
        fi
        # per-GPU containers — ${TARGET_TAG} names an extra one beside the standard
        for gpu in ${gpu_list}; do
            _cname="${TARGET_IMAGE}_${gpu}${TARGET_TAG}${suffix}"
            containers+=("${_cname}|docker run -d --init ${swap_opt} ${nopyc_opt} ${wandb_opt} ${net_opt} --gpus device=${gpu} ${shm_opt} ${vol} ${opts} --name ${_cname} ${image} sleep infinity")
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
