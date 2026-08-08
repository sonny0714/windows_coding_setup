#!/bin/bash
# ============================================
#  Run Scan — discover experiment run dirs across servers (run_id readback + completion)
#
#  Usage:
#    ./run_scan.sh -p <project> -t all                       — every run dir on all active servers
#    ./run_scan.sh -p <project> -t <server> -s 6h            — only dirs modified in the last 6h
#    ./run_scan.sh -p <project> -t all -m model.core.algo_name=vanilla_sac
#    ./run_scan.sh -p <project> -t all -d file:finished -o md
#    ./run_scan.sh -p <project> -t all -d file:finished -w 30
#    ./run_scan.sh -p <project> -t all -d file:finished -D -o ids | artifact_sync.sh -a c -p <project> -t all -R -
#
#  Options:
#    -p <project> target project — required
#    -t <server>  target server — required ("all" = all active servers, incl. this one)
#    -s <since>   only dirs modified after: 6h / 2d / 30m / "YYYY-MM-DD HH:MM"
#    -m <k=v>     config.json filter, repeatable (AND); value accepts a * glob
#    -k <key>     extra config.json key printed as a column, repeatable
#    -d <spec>    completion predicate, repeatable:
#                   file:online.jax             — path exists inside the run dir
#                   glob:rollout/iter*.npz>=200 — glob count meets the bound
#    -D           keep only rows whose status is done (needs -d)
#    -w <n>       block until n runs report done, then print (needs -d)
#    -i <sec>     poll interval for -w (default 240)
#    -o <fmt>     output format: tsv (default) | md | ids
#    -c <name>    per-run config filename (default config.json)
#    -h           show help
#
#  Reads only — never writes, moves, or deletes anything. Feed -o ids into
#  artifact_sync.sh -R to collect exactly the runs a scan matched.
#
#  run_id is the on-disk dir name under artifacts/runs/{project}/, minted at
#  runtime — this is the value the run tracking table wants, never the wandb name.
#
#  `-d file:finished` is the canonical completion test: the runner writes that
#  marker only after reaching its documented end. check_points/ is created at
#  launch and stays empty when the stage checkpoints nothing, so it never meant
#  completion — do not judge a run by it.
#
#  The -w count is UNIQUE run_ids across servers, never a per-server sum: a
#  relaunched leg leaves a dir on two servers and a sum overshoots the target.
#
#  Requires:
#    - "base_{PROJECT_USER}" docker container running on each target server
#
#  Path conventions:
#    docker exec (scan) : target_mnt_path paths
# ============================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
eval "$(python3 "${SCRIPT_DIR}/exec.py" "$(cd "${SCRIPT_DIR}/../../../.." && pwd)/md_files/users/users.yaml" "sonny")"
source "${SCRIPT_DIR}/utils.sh"

_show_help() { sed -n '2,/^# ====.*$/p' "$0" | sed 's/^# \?//'; exit 0; }

TARGET_PROJECT=""
TARGET_SERVER=""
SINCE=""
CONFIG_NAME=""
WAIT_COUNT=""
ONLY_DONE=false
POLL_INTERVAL=240
OUT_FORMAT="tsv"
SHOW_HELP=false
MATCH_LIST=()
KEY_LIST=()
DONE_LIST=()

while getopts "p:t:s:m:k:d:Dw:i:o:c:h" opt; do
    case $opt in
        p) TARGET_PROJECT="$OPTARG" ;;
        t) TARGET_SERVER="$OPTARG" ;;
        s) SINCE="$OPTARG" ;;
        m) MATCH_LIST+=("$OPTARG") ;;
        k) KEY_LIST+=("$OPTARG") ;;
        d) DONE_LIST+=("$OPTARG") ;;
        D) ONLY_DONE=true ;;
        w) WAIT_COUNT="$OPTARG" ;;
        i) POLL_INTERVAL="$OPTARG" ;;
        o) OUT_FORMAT="$OPTARG" ;;
        c) CONFIG_NAME="$OPTARG" ;;
        h) SHOW_HELP=true ;;
        *) echo "Usage: $0 -p <project> -t <server|all> [-s since] [-m k=v] [-k key] [-d spec] [-D] [-w n] [-o tsv|md|ids] [-h]"; exit 1 ;;
    esac
done

[ "${SHOW_HELP}" = true ] && _show_help

if [ -z "${TARGET_PROJECT}" ]; then
    echo "[ERROR] -p option required: specify a project" >&2
    exit 1
fi

if [ -z "${TARGET_SERVER}" ]; then
    echo "[ERROR] -t option required: specify a server or 'all'" >&2
    exit 1
fi

case "${OUT_FORMAT}" in
    tsv|md|ids) ;;
    *) echo "[ERROR] -o must be tsv, md, or ids" >&2; exit 1 ;;
esac

if [ ${#DONE_LIST[@]} -eq 0 ] && { [ -n "${WAIT_COUNT}" ] || [ "${ONLY_DONE}" = true ]; }; then
    echo "[ERROR] -w / -D need at least one -d predicate to decide what 'done' means" >&2
    exit 1
fi

if ! is_known_git_project "${TARGET_PROJECT}"; then
    echo "[ERROR] unknown project: ${TARGET_PROJECT}" >&2
    exit 1
fi

# Base containers ship without tzdata, so a zone NAME silently degrades to UTC.
# A POSIX offset string (KST +0900 → "LOC-9") needs no zoneinfo, so every server
# stamps mtime in this caller's wall clock.
_offset=$(date +%z)
_sign=${_offset:0:1}; _hh=${_offset:1:2}; _mm=${_offset:3:2}
[ "${_sign}" = "+" ] && _sign="-" || _sign="+"
SCAN_TZ="LOC${_sign}${_hh#0}"
[ "${_mm}" != "00" ] && SCAN_TZ="${SCAN_TZ}:${_mm}"

PY_PATH="${SCRIPT_DIR}/run_scan.py"
[ -f "${PY_PATH}" ] || { echo "[ERROR] scanner not found: ${PY_PATH}" >&2; exit 1; }

declare -n _base_img="DOCKER_base"
DOCKER_VOL="${_base_img[target_mnt_path]}"
unset -n _base_img

# Scanner arguments shared by every server
PY_ARGS=()
[ -n "${SINCE}" ] && PY_ARGS+=(--since "${SINCE}")
[ -n "${CONFIG_NAME}" ] && PY_ARGS+=(--config "${CONFIG_NAME}")
for _m in "${MATCH_LIST[@]}"; do PY_ARGS+=(--match "${_m}"); done
for _k in "${KEY_LIST[@]}"; do PY_ARGS+=(--key "${_k}"); done
for _d in "${DONE_LIST[@]}"; do PY_ARGS+=(--done "${_d}"); done

# Resolve targets once — the wait loop must not re-probe the server list
mapfile -t TARGET_LIST < <(resolve_target_servers "${TARGET_SERVER}")
if [ ${#TARGET_LIST[@]} -eq 0 ]; then
    echo "[ERROR] no active target server resolved from '${TARGET_SERVER}'" >&2
    exit 1
fi

SCAN_LIST=()
for _name in "${TARGET_LIST[@]}"; do
    if ! in_git_available "${_name}" "${TARGET_PROJECT}"; then
        echo "[SKIP] ${_name} — project '${TARGET_PROJECT}' not available" >&2
        continue
    fi
    # A read-only sweep degrades on an unreachable box rather than aborting —
    # losing one server's rows beats losing the whole scan.
    if ! ensure_base "${_name}" >&2; then
        echo "[SKIP] ${_name} — base container unreachable" >&2
        continue
    fi
    SCAN_LIST+=("${_name}")
done

if [ ${#SCAN_LIST[@]} -eq 0 ]; then
    echo "[ERROR] no server hosts project '${TARGET_PROJECT}'" >&2
    exit 1
fi

# Pipe the scanner into the server's base container. stdin is redirected from the
# script file explicitly so ssh cannot swallow the caller's stdin.
_scan_server() {
    local name="$1"
    declare -n _srv="SERVER_${name}"
    local user="${_srv[ssh_user]}"
    local ip="${_srv[ip]}"
    unset -n _srv
    local opts; opts=$(build_ssh_opts "$name")

    local args=(--root "${DOCKER_VOL}/artifacts/runs/${TARGET_PROJECT}" --server "${name}" "${PY_ARGS[@]}")

    # Containers run UTC while the caller reads KST, and each server may differ
    # again — stamping every mtime in the caller's zone keeps one clock across
    # the whole scan instead of one per container.
    if is_local_server "$name"; then
        docker exec -i -e "TZ=${SCAN_TZ}" "${BASE_CONTAINER}" python3 - "${args[@]}" < "${PY_PATH}" 2>/dev/null
    else
        ssh ${opts} ${user}@${ip} "docker exec -i -e TZ=$(printf '%q' "${SCAN_TZ}") ${BASE_CONTAINER} python3 - $(printf '%q ' "${args[@]}")" < "${PY_PATH}" 2>/dev/null
    fi
}

_scan_all() {
    local name
    for name in "${SCAN_LIST[@]}"; do
        _scan_server "${name}"
    done
}

# UNIQUE run_ids (column 2) whose status is done — never a per-server sum
_count_done() {
    awk -F'\t' '$4 == "done" { seen[$2] = 1 } END { print length(seen) }' <<< "$1"
}

_emit() {
    local rows="$1"
    local header="server	run_id	mtime	status"
    local _k
    for _k in "${KEY_LIST[@]}"; do header="${header}	${_k}"; done

    case "${OUT_FORMAT}" in
        ids)
            [ -n "${rows}" ] && awk -F'\t' '{ print $2 }' <<< "${rows}" | sort -u
            ;;
        md)
            awk -F'\t' -v head="${header}" '
                BEGIN { n = split(head, h, "\t")
                        row = ""; sep = ""
                        for (i = 1; i <= n; i++) { row = row "| " h[i] " "; sep = sep "|---" }
                        print row "|"; print sep "|" }
                { row = ""
                  for (i = 1; i <= n; i++) { v = (i <= NF && $i != "") ? $i : "-"
                                             if (i == 2) v = "`" v "`"
                                             row = row "| " v " " }
                  print row "|" }' <<< "${rows}"
            ;;
        *)
            printf '%s\n' "${header}"
            [ -n "${rows}" ] && printf '%s\n' "${rows}"
            ;;
    esac
}

ROWS="$(_scan_all)"

if [ -n "${WAIT_COUNT}" ]; then
    while :; do
        _n=$(_count_done "${ROWS}")
        echo "[$(date +%H:%M:%S)] done=${_n}/${WAIT_COUNT}" >&2
        [ "${_n}" -ge "${WAIT_COUNT}" ] && break
        sleep "${POLL_INTERVAL}"
        ROWS="$(_scan_all)"
    done
fi

# -D must gate every format: an unfiltered `-o ids` piped into a collect would
# pull half-written run dirs alongside the finished ones.
if [ "${ONLY_DONE}" = true ] && [ -n "${ROWS}" ]; then
    ROWS=$(awk -F'\t' '$4 == "done"' <<< "${ROWS}")
fi

_emit "${ROWS}"

if [ -n "${ROWS}" ]; then
    echo "[run_scan] ${TARGET_PROJECT}: $(printf '%s\n' "${ROWS}" | wc -l) run(s) across ${#SCAN_LIST[@]} server(s)" >&2
else
    echo "[run_scan] ${TARGET_PROJECT}: no run dir matched" >&2
fi
