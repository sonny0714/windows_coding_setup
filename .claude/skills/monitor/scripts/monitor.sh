#!/bin/bash
# ============================================
#  Monitor — multi-server CPU/GPU dashboard, one tmux session per group
#
#  Opens a dedicated tmux SESSION per group and SSHes each pane into a
#  server to run a live monitor. `mon` (gpu → session "mon") and `mon_pi`
#  (pi → session "mon_pi") each own their session, so attaching, detaching,
#  or killing one never disturbs the other.
#
#  Usage:
#    ./monitor.sh                       — GPU group, two columns, attach
#    ./monitor.sh -g pi                 — Pi/CPU group, tiled grid, attach
#    ./monitor.sh -m combo              — force nvidia-smi + top combo watch
#    ./monitor.sh -m nvitop             — nvitop only (no fallback)
#    ./monitor.sh -m gpu                — plain `watch nvidia-smi` (old behavior)
#    ./monitor.sh -m htop               — htop only (CPU focus)
#    ./monitor.sh -l "z3,ada2,z4" -r "th1,n2,deep"   — custom columns
#    ./monitor.sh -K                    — kill the GPU session ("mon")
#    ./monitor.sh -g pi -K              — kill the Pi session ("mon_pi")
#
#  Options:
#    -g <group>  gpu (default) | pi
#                  gpu → servers WITH a gpu_available_list, two columns,
#                        session "mon", default mode auto
#                  pi  → active remote servers with NO gpu, tiled grid,
#                        session "mon_pi", default mode cpu
#    -m <mode>   auto | combo | nvitop | nvtop | gpu | htop | cpu
#                  auto  → nvitop, else nvtop, else combo watch
#                  combo → watch: nvidia-smi + load + top CPU procs
#                  gpu   → watch nvidia-smi
#                  htop  → htop
#                  cpu   → compact 5-line CPU% / MEM% / temp+load /
#                          physical link (iface, signal, PHY rate, channel) /
#                          live rx-tx throughput + wifi retry delta (no deps)
#    -l <list>   comma-separated LEFT column servers  (pi: whole list)
#    -r <list>   comma-separated RIGHT column servers (unused for pi)
#    -n <name>   tmux session name (default: per group — mon / mon_pi)
#    -w <name>   tmux window name (default: per group — mon / pi)
#    -k          kill an existing session of the same name first, then recreate
#    -K          kill the whole session and EXIT (terminate its panes at once)
#    -h          show help
#
#  Notes:
#    - Server connection info (user/ip/port/key/agent) is read from the
#      generated configuration.sh — same source the other core topic scripts use.
#    - Each pane uses `ssh -t` (interactive pty) with agent forwarding and
#      keepalive; the remote command is base64-wrapped to avoid quote clashes.
#    - Detach with `Ctrl-b d`; reattach with `tmux attach -t <name>`.
# ============================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
eval "$(python3 "${SCRIPT_DIR}/exec.py" "$(cd "${SCRIPT_DIR}/../../../.." && pwd)/md_files/users/users.yaml" "sonny")"
source "${SCRIPT_DIR}/utils.sh"

_show_help() { sed -n '2,/^# ====.*$/p' "$0" | sed 's/^# \?//'; exit 0; }

# Defaults
GROUP="gpu"
MODE=""
LEFT=""
RIGHT=""
SESSION=""
WINDOW=""
KILL_EXISTING=false
KILL_ONLY=false
LEFT_SET=false
RIGHT_SET=false

while getopts "g:m:l:r:n:w:kKh" opt; do
    case $opt in
        g) GROUP="$OPTARG" ;;
        m) MODE="$OPTARG" ;;
        l) LEFT="$OPTARG"; LEFT_SET=true ;;
        r) RIGHT="$OPTARG"; RIGHT_SET=true ;;
        n) SESSION="$OPTARG" ;;
        w) WINDOW="$OPTARG" ;;
        k) KILL_EXISTING=true ;;
        K) KILL_ONLY=true ;;
        h) _show_help ;;
        *) echo "Usage: $0 [-g group] [-m mode] [-l left] [-r right] [-n name] [-w win] [-k|-K] [-h]"; exit 1 ;;
    esac
done

# Group decides the session name, the default mode, and the default server set.
# The session name is what -K targets, so each group closes independently.
case "$GROUP" in
    gpu) : "${SESSION:=mon}";    : "${WINDOW:=mon}"; : "${MODE:=auto}" ;;
    pi)  : "${SESSION:=mon_pi}"; : "${WINDOW:=pi}";  : "${MODE:=cpu}"  ;;
    *)   echo "[ERROR] unknown group '$GROUP' (expected: gpu | pi)" >&2; exit 1 ;;
esac

# With no -l/-r given, default to the active servers, split by group:
#   gpu → servers with a non-empty gpu_available_list; single-GPU boxes go
#         LEFT, multi-GPU (2+) go RIGHT.
#   pi  → active remote servers with an EMPTY gpu_available_list (the Pi
#         fleet). This is the exact complement of the gpu rule, so a server
#         never lands in both windows.
#
# A local-only server (server_remote=false) runs the snippet on whatever host
# mon is launched from, with no ssh — so it is only valid when we ARE that
# machine. On any other host (e.g. deep) it would silently monitor the current
# host while labeled as the local PC. detect_local_server tells us which entry
# the current machine is; local-only servers that aren't it are skipped.
if [ "${LEFT_SET}" = false ] && [ "${RIGHT_SET}" = false ]; then
    detect_local_server || true
    _one=(); _multi=()
    for _s in "${SERVER_LIST[@]}"; do
        declare -p "SERVER_${_s}" >/dev/null 2>&1 || continue
        declare -n _srv="SERVER_${_s}"
        if [ "${_srv[server_active_status]}" = "true" ] \
           && { [ "${_srv[server_remote]}" = "true" ] || [ "${_s}" = "${DETECTED_SERVER}" ]; }; then
            if [ "$GROUP" = "pi" ]; then
                [ -z "${_srv[gpu_available_list]}" ] && [ "${_srv[server_remote]}" = "true" ] \
                    && _one+=("${_s}")
            elif [ -n "${_srv[gpu_available_list]}" ]; then
                read -r -a _gpus <<< "${_srv[gpu_available_list]}"
                if [ "${#_gpus[@]}" -le 1 ]; then _one+=("${_s}"); else _multi+=("${_s}"); fi
            fi
        fi
        unset -n _srv
    done
    LEFT="$(IFS=,; printf '%s' "${_one[*]}")"
    RIGHT="$(IFS=,; printf '%s' "${_multi[*]}")"
fi

command -v tmux >/dev/null 2>&1 || { echo "[ERROR] tmux not installed"; exit 1; }

# -K: terminate this group's whole session and exit — the other group lives in
# its own session, so it is untouched. Sweeps the exact session AND postfixed
# duplicates (mon, mon-1, mon_2, mon2). The postfix must be NUMERIC: a broader
# class like [-_0-9] would make "mon -K" match — and kill — "mon_pi".
if [ "${KILL_ONLY}" = true ]; then
    _hit=false
    while IFS= read -r _sess; do
        [ -z "${_sess}" ] && continue
        tmux kill-session -t "=${_sess}" 2>/dev/null \
            && { _hit=true; echo "[OK] terminated session '${_sess}'"; }
    done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null \
                 | grep -E "^${SESSION}([-_]?[0-9]+)?$")
    [ "${_hit}" = false ] && echo "[INFO] no session '${SESSION}'"
    exit 0
fi

# Build the remote monitor snippet for the chosen mode. The snippet runs on the
# remote host; nvitop/nvtop need a login shell to pick up ~/.local/bin on PATH.
_remote_snippet() {
    case "$MODE" in
        nvitop) printf '%s' 'exec nvitop -m auto' ;;
        nvtop)  printf '%s' 'exec nvtop' ;;
        htop)   printf '%s' 'exec htop' ;;
        gpu)    printf '%s' 'exec watch -n 2 nvidia-smi' ;;
        combo)  printf '%s' "$_COMBO_WATCH" ;;
        cpu)    printf '%s' "$_CPU_WATCH" ;;
        auto)
            printf '%s\n' \
                'if command -v nvitop >/dev/null 2>&1; then exec nvitop -m auto; fi' \
                'if command -v nvtop  >/dev/null 2>&1; then exec nvtop; fi' \
                "$_COMBO_WATCH" ;;
        *) echo "[ERROR] unknown mode '$MODE'" >&2; exit 1 ;;
    esac
}

# Combined CPU+GPU watch — no external tool required (nvidia-smi + procps).
# CPU side uses `top -bn2` (two samples) so %CPU is the live delta, not the
# lifetime average `ps`/`top -bn1` would report; awk keeps only the 2nd sample.
# top's header line already carries the load average, so no separate uptime.
_COMBO_WATCH='exec watch -c -n 2 '\''echo "### GPU (util% / mem MiB / temp) ###"; nvidia-smi --query-gpu=index,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits; echo; echo "### CPU (live) ###"; top -bn2 -d 0.3 | awk "/^top - /{n++} n==2" | head -n 18'\'''

# Compact CPU/RAM/link readout for the Pi fleet — exactly 5 lines, so 25 of these
# fit a 5x5 tiled grid where htop (10+ header lines alone) would render as a
# clipped smear. Reads /proc directly: no htop/top/procps needed on the Pi,
# and CPU% is a real 1s delta of /proc/stat rather than a lifetime average.
#
# Wrapped in its own base64 layer because `watch` hands its command to `sh -c`:
# an inline awk program would have $1/$2 eaten by that shell first. The encoded
# blob has no metacharacters, so nothing can re-interpret it on the way in.
_PI_STAT_BODY=$(cat <<'PISTAT'
iface=$(ip route show default 2>/dev/null | awk '{for (k = 1; k <= NF; k++) if ($k == "dev") {print $(k+1); exit}}')
[ -z "$iface" ] && iface=$(ls /sys/class/net 2>/dev/null | grep -vx lo | head -1)
stat_dir="/sys/class/net/${iface}/statistics"
# retry column ($9) of /proc/net/wireless — a climbing delta means the link is
# re-sending frames, which shows up as a stall long before signal dBm moves.
wretry() { awk 'NR > 2 {print $9 + 0; exit}' /proc/net/wireless 2>/dev/null; }

# One 1s window samples CPU, link bytes and wifi retries together, so the three
# deltas describe the same instant instead of three staggered ones.
read -r _ u1 n1 s1 i1 w1 q1 x1 t1 _ < /proc/stat
rx1=$(cat "${stat_dir}/rx_bytes" 2>/dev/null); tx1=$(cat "${stat_dir}/tx_bytes" 2>/dev/null)
re1=$(wretry)
sleep 1
read -r _ u2 n2 s2 i2 w2 q2 x2 t2 _ < /proc/stat
rx2=$(cat "${stat_dir}/rx_bytes" 2>/dev/null); tx2=$(cat "${stat_dir}/tx_bytes" 2>/dev/null)
re2=$(wretry)
: "${rx1:=0}" "${rx2:=0}" "${tx1:=0}" "${tx2:=0}" "${re1:=0}" "${re2:=0}"
busy=$(( (u2+n2+s2+q2+x2+t2) - (u1+n1+s1+q1+x1+t1) ))
idle=$(( (i2+w2) - (i1+w1) ))
awk -v b="$busy" -v i="$idle" 'BEGIN {
    t = b + i; p = (t > 0) ? int(100 * b / t + 0.5) : 0
    n = int(p / 10); for (k = 0; k < 10; k++) bar = bar (k < n ? "#" : ".")
    printf "CPU %3d%% [%s]\n", p, bar }'
awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {
    u = t - a; p = int(100 * u / t + 0.5)
    n = int(p / 10); for (k = 0; k < 10; k++) bar = bar (k < n ? "#" : ".")
    printf "MEM %3d%% [%s] %.1f/%.1fG\n", p, bar, u/1048576, t/1048576 }' /proc/meminfo
temp="n/a"
[ -r /sys/class/thermal/thermal_zone0/temp ] \
    && temp=$(awk '{printf "%.0fC", $1/1000}' /sys/class/thermal/thermal_zone0/temp)
printf 'TMP %-5s load %s\n' "$temp" "$(cut -d' ' -f1-3 /proc/loadavg)"

# iw lives in /usr/sbin, which is not on a non-root PATH — `command -v iw` finds
# nothing on a Pi that has it installed, so probe the absolute path first. It
# needs no root: `iw dev link` is a plain netlink query.
iw_bin=/usr/sbin/iw
[ -x "$iw_bin" ] || iw_bin=$(command -v iw 2>/dev/null)
link=""
[ -n "$iw_bin" ] && [ -n "$iface" ] && link=$("$iw_bin" dev "$iface" link 2>/dev/null)

if [ -n "${link##*Not connected*}" ] && [ -n "$(printf '%s' "$link" | grep -i '^[[:space:]]*signal:')" ]; then
    # Wireless: PHY rates are what the link actually negotiated, so a Pi that
    # quietly fell back to a lower MCS is visible without touching throughput.
    printf '%s' "$link" | awk -v ifc="$iface" '
        /signal:/     {sig = $2}
        /freq:/       {f = $2 + 0}
        /rx bitrate:/ {rxb = $3 + 0}
        /tx bitrate:/ {txb = $3 + 0}
        END {
            if (f >= 5000)                 ch = (f - 5000) / 5
            else if (f == 2484)            ch = 14
            else if (f >= 2412 && f <= 2472) ch = (f - 2407) / 5
            else                           ch = 0
            printf "LNK %s %sdBm %d/%dMbps %s\n", ifc, sig, rxb, txb,
                   (ch > 0 ? sprintf("ch%d", ch) : sprintf("%dMHz", f)) }'
else
    # Wired (or a wifi iface with no iw): sysfs speed/duplex. Both read back
    # "Invalid argument" on a wireless device, hence the guard.
    spd=$(cat "/sys/class/net/${iface}/speed" 2>/dev/null)
    dup=$(cat "/sys/class/net/${iface}/duplex" 2>/dev/null)
    ops=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null)
    if [ -n "$spd" ] && [ "$spd" -gt 0 ] 2>/dev/null; then
        printf 'LNK %s %s %sMbps %s\n' "$iface" "${ops:-?}" "$spd" "${dup:-?}"
    else
        printf 'LNK %s %s\n' "${iface:-none}" "${ops:-down}"
    fi
fi

awk -v r1="$rx1" -v r2="$rx2" -v t1="$tx1" -v t2="$tx2" -v e1="$re1" -v e2="$re2" '
    # bytes-over-1s -> Mbps: *8 bits, /1e6 (network decimal megabit).
    function mbps(v) { return sprintf("%.2fMbps", (v < 0 ? 0 : v) * 8 / 1e6) }
    BEGIN {
        dr = r2 - r1; dt = t2 - t1; de = e2 - e1
        printf "NET rx %s tx %s re+%d\n", mbps(dr), mbps(dt), (de > 0 ? de : 0)
    }'
PISTAT
)
_PI_STAT_ENC="$(printf '%s' "$_PI_STAT_BODY" | base64 -w0)"
# -t drops watch's 2-line header (the pane border already names the server).
_CPU_WATCH="exec watch -t -n 2 'bash -c \"\$(echo ${_PI_STAT_ENC} | base64 -d)\"'"

# Build the full pane command (ssh + base64-wrapped remote snippet) for a server.
# Local servers (server_remote != true) run the snippet directly, no ssh.
_pane_cmd() {
    local name="$1"
    if ! declare -p "SERVER_${name}" >/dev/null 2>&1; then
        echo "echo '[ERROR] unknown server: ${name}'; echo; read -p 'enter to close...'"
        return
    fi
    declare -n _srv="SERVER_${name}"

    local snippet enc
    snippet="$(_remote_snippet)"
    enc="$(printf '%s' "$snippet" | base64 -w0)"

    if [ "${_srv[server_remote]}" != "true" ]; then
        unset -n _srv
        printf '%s' "bash -lc \"\$(echo ${enc} | base64 -d)\""
        return
    fi

    local agent="" port_opt="" key_opt=""
    [ "${_srv[ssh_forward_agent]}" = "true" ] && agent="-A"
    [ "${_srv[port]}" != "22" ] && [ -n "${_srv[port]}" ] && port_opt="-p ${_srv[port]}"
    [ -n "${_srv[ssh_key]}" ] && key_opt="-i ${_srv[ssh_key]}"
    local user="${_srv[ssh_user]}" ip="${_srv[ip]}"
    unset -n _srv

    local alive="-o ServerAliveInterval=30 -o ServerAliveCountMax=120 -o StrictHostKeyChecking=accept-new"
    local remote_run="bash -lc \"\$(echo ${enc} | base64 -d)\""
    printf '%s' "ssh -t ${agent} ${alive} ${port_opt} ${key_opt} ${user}@${ip} '${remote_run}'"
}

# tmux percentage-split flag differs by version: 3.1+ uses `-l N%`, older uses
# `-p N`. Pick the right one once from `tmux -V`.
_PCT_FLAG="-l"; _PCT_SUFFIX="%"
_tmux_ver="$(tmux -V 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)"
_tmux_major="${_tmux_ver%%.*}"; _tmux_minor="${_tmux_ver##*.}"
if [ "${_tmux_major:-0}" -lt 3 ] || { [ "${_tmux_major:-0}" -eq 3 ] && [ "${_tmux_minor:-0}" -lt 1 ]; }; then
    _PCT_FLAG="-p"; _PCT_SUFFIX=""
fi

# Split a column pane into k evenly-sized rows. Echoes the k pane ids top→bottom.
# Splitting the freshly created bottom pane with a shrinking percentage keeps
# every row the same height regardless of k.
_build_column() {
    local pane="$1" k="$2"
    local ids=("$pane") i l new
    for ((i = 0; i < k - 1; i++)); do
        l=$(( 100 * (k - 1 - i) / (k - i) ))
        new=$(tmux split-window -v "$_PCT_FLAG" "${l}${_PCT_SUFFIX}" -t "$pane" -P -F '#{pane_id}')
        ids+=("$new")
        pane="$new"
    done
    echo "${ids[@]}"
}

# Grow a window to k tiled panes. Re-tiling after every split is what makes 25
# panes fit: split alone halves the active pane until it hits tmux's minimum
# and errors out, whereas `select-layout tiled` redistributes the whole window
# each round so there is always room for the next one.
_build_tiled() {
    local target="$1" k="$2" i
    for ((i = 1; i < k; i++)); do
        tmux split-window -t "$target" >/dev/null 2>&1 || {
            echo "[WARN] terminal too small for ${k} panes — stopped at ${i}" >&2
            break
        }
        tmux select-layout -t "$target" tiled >/dev/null 2>&1
    done
    tmux list-panes -t "$target" -F '#{pane_id}' | tr '\n' ' '
}

IFS=',' read -r -a left_servers  <<< "$LEFT"
IFS=',' read -r -a right_servers <<< "$RIGHT"

_target="${SESSION}:${WINDOW}"

if [ "${KILL_EXISTING}" = true ]; then
    tmux kill-session -t "=${SESSION}" 2>/dev/null
fi

# Each group owns its whole session: attach if it exists, else build it.
if tmux has-session -t "=${SESSION}" 2>/dev/null; then
    echo "[INFO] session '${SESSION}' already exists — attaching (use -k to recreate)"
else
    # -x/-y: an unattached session would otherwise be built at tmux's 80x24
    # default-size, where a 25-pane tile has no room. The window resizes to
    # the real client on attach.
    tmux new-session -d -s "$SESSION" -n "$WINDOW" -x 250 -y 60
    tmux set-option -t "$SESSION" pane-border-status top >/dev/null 2>&1
    tmux set-option -t "$SESSION" mouse on            >/dev/null 2>&1
    base=$(tmux list-panes -t "$_target" -F '#{pane_id}' | head -1)

    # select-window / switch-client below address "${SESSION}:${WINDOW}", so
    # the window name must not drift. tmux's automatic-rename would retitle
    # the window after whatever the active pane runs.
    tmux set-option -w -t "$_target" automatic-rename off >/dev/null 2>&1

    if [ "$GROUP" = "pi" ]; then
        # One flat list for the grid — the two-column split is a GPU-group idea.
        pi_servers=("${left_servers[@]}" "${right_servers[@]}")
        read -r -a pane_ids <<< "$(_build_tiled "$_target" "${#pi_servers[@]}")"
        for i in "${!pi_servers[@]}"; do
            name="${pi_servers[$i]}"; pane="${pane_ids[$i]}"
            [ -z "$pane" ] && break
            tmux select-pane -t "$pane" -T "$name"
            tmux send-keys   -t "$pane" "$(_pane_cmd "$name")" C-m
        done
    else
        right_base=$(tmux split-window -h -t "$base" -P -F '#{pane_id}')

        read -r -a left_ids  <<< "$(_build_column "$base"       "${#left_servers[@]}")"
        read -r -a right_ids <<< "$(_build_column "$right_base"  "${#right_servers[@]}")"

        for i in "${!left_servers[@]}"; do
            name="${left_servers[$i]}"; pane="${left_ids[$i]}"
            tmux select-pane -t "$pane" -T "$name"
            tmux send-keys   -t "$pane" "$(_pane_cmd "$name")" C-m
        done
        for i in "${!right_servers[@]}"; do
            name="${right_servers[$i]}"; pane="${right_ids[$i]}"
            tmux select-pane -t "$pane" -T "$name"
            tmux send-keys   -t "$pane" "$(_pane_cmd "$name")" C-m
        done
    fi

    tmux select-pane -t "$base"
fi

# Attach (or switch if already inside tmux), landing on this group's window.
tmux select-window -t "$_target" 2>/dev/null
if [ -n "$TMUX" ]; then
    tmux switch-client -t "$_target"
else
    tmux attach-session -t "$_target"
fi
