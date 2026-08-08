#!/bin/bash
# ============================================
#  Exec utilities — shared functions for core/<topic>/<topic>.sh scripts
# ============================================

# Derived from configuration.sh
BASE_CONTAINER="base_${PROJECT_USER}"

# Path of the docker topic script, resolved from this file's own location so
# callers need not know the layout. Two layouts source this file:
#   alias    — core/common/utils.sh  → sibling topic dir core/docker/docker.sh
#   skill    — .claude/skills/<name>/scripts/utils.sh → same dir (docker skill only)
_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${_UTILS_DIR}/../docker/docker.sh" ]; then
    DOCKER_SCRIPT="${_UTILS_DIR}/../docker/docker.sh"
else
    DOCKER_SCRIPT="${_UTILS_DIR}/docker.sh"
fi

# Print a "===" banner with [name] ip:port for the given server.
# Usage: print_target_banner <server_name>
print_target_banner() {
    declare -n _srv="SERVER_${1}"
    local _ident
    if [ "${_srv[server_remote]}" = "true" ]; then
        _ident="${_srv[ip]}:${_srv[port]}"
    else
        _ident="${_srv[hostname]:-localhost} (local)"
    fi
    echo "=================================="
    echo "[${1}] ${_ident}"
    echo "=================================="
    unset -n _srv
}

# Print a "===" banner with arbitrary content line.
# Usage: print_banner_line <content>
print_banner_line() {
    echo "=================================="
    echo "$1"
    echo "=================================="
}

# Build SSH options from server config
# Usage: ssh_opts=$(build_ssh_opts "$name")
build_ssh_opts() {
    local name="$1"
    declare -n _srv="SERVER_${name}"
    # LogLevel=ERROR silences the "Warning: Permanently added ..." host-key noise
    # so run_on_server can pass real remote stderr through instead of dumping the
    # whole stream to /dev/null (which also hid every genuine failure message).
    local opts="-o LogLevel=ERROR"
    [ "${_srv[port]}" != "22" ] && [ -n "${_srv[port]}" ] && opts="${opts} -p ${_srv[port]}"
    [ -n "${_srv[ssh_key]}" ] && opts="${opts} -i ${_srv[ssh_key]}"
    unset -n _srv
    echo "${opts}"
}

# Run command on server (local or remote via SSH).
# Local detection uses is_local_server (exact-match against every hostname IP).
# Usage: run_on_server "$name" "$cmd"
run_on_server() {
    local name="$1"
    local cmd="$2"
    declare -n _srv="SERVER_${name}"
    local user="${_srv[ssh_user]}"
    local ip="${_srv[ip]}"
    local opts=$(build_ssh_opts "$name")
    unset -n _srv

    if is_local_server "$name"; then
        bash -c "${cmd}"
    else
        # Remote stderr flows through (matching the local branch) — a failing
        # remote command must say WHY on the caller's terminal. A probe that wants
        # silence suppresses at ITS call site, not here for everyone.
        ssh ${opts} ${user}@${ip} "${cmd}"
    fi
}

# Ensure base container is running on server
# If stopped → docker start, if not found → docker.sh -i base -t <server>
# Usage: ensure_base "$name"
ensure_base() {
    local name="$1"
    local cname="base_${PROJECT_USER}"

    # Check if base is running. tail -1 because a remote bashrc that prints on a
    # non-interactive shell (an alias hook warning, a submodule notice) lands in
    # this capture, and an exact "yes" compare would then read a healthy
    # container as missing.
    local is_running
    is_running=$(run_on_server "$name" "docker ps --format '{{.Names}}' | grep -qx '${cname}' && echo yes" | tail -1)
    [ "${is_running}" = "yes" ] && return 0

    # Try start (stopped container) or create (no container)
    local result
    result=$(run_on_server "$name" "if docker ps -a --format '{{.Names}}' | grep -qx '${cname}'; then echo '  [${cname}] stopped, restarting...'; docker start ${cname} >/dev/null; else echo '  [${cname}] not found, creating...'; fi")
    echo "${result}"

    if echo "${result}" | grep -q "not found"; then
        "${DOCKER_SCRIPT}" -i base -t "${name}"
    fi

    # Verify
    is_running=$(run_on_server "$name" "docker ps --format '{{.Names}}' | grep -qx '${cname}' && echo yes" | tail -1)
    if [ "${is_running}" != "yes" ]; then
        echo "  [ERROR] ${cname} container failed to start on ${name}"
        return 1
    fi
    return 0
}

# Ensure SSH agent is running and key is loaded
# Usage: ensure_ssh_agent
ensure_ssh_agent() {
    if [ -z "${SSH_AUTH_SOCK}" ]; then
        eval "$(ssh-agent -s)" > /dev/null
    fi
    if ! ssh-add -l > /dev/null 2>&1; then
        local _key="${SSH_DEFAULT_KEY/#\~/$HOME}"
        ssh-add "${_key}" || { echo "[ERROR] Failed to add SSH key to agent: ${_key}"; return 1; }
    fi
}

# ============================================
#  Target / available-list helpers
#  Shared across core/*/<topic>.sh — single source of truth for "what is a valid
#  target?" and "is this project/image available on this server?"
#
#  Defaults (from configuration_default.yaml) are merged into GIT_PROJECT_LIST,
#  DOCKER_LIST, and every server's git_available_list / docker_available_list
#  by yaml_to_bash.py and setup.sh, so the helpers below treat all
#  entries uniformly — no special-case "default" handling.
# ============================================

# Membership test against the global git project list.
# Usage: is_known_git_project <project>
is_known_git_project() {
    local _p
    for _p in "${GIT_PROJECT_LIST[@]}"; do
        [ "$_p" = "$1" ] && return 0
    done
    return 1
}

# Membership test against the global docker image list.
# Usage: is_known_docker_image <image>
is_known_docker_image() {
    local _d
    for _d in "${DOCKER_LIST[@]}"; do
        [ "$_d" = "$1" ] && return 0
    done
    return 1
}

# Map `uname -m` (or a docker platform string) → docker arch key. Variants
# (arm64/v8, arm/v7) collapse to the base arch: amd64-vs-arm64 is the only split
# our servers actually have. Mirrored by platform_arch() in core/config/yaml_to_bash.py
# and the _my_arch case in bash_alias/docker.sh — the three must not drift.
# Usage: docker_arch <uname-m|platform>
docker_arch() {
    local _a="${1#linux/}"
    _a="${_a%%/*}"
    case "${_a}" in
        x86_64|amd64)          echo "amd64" ;;
        aarch64|arm64|armv8*)  echo "arm64" ;;
        armv7*|armv6*|armhf)   echo "arm" ;;
        i386|i686)             echo "386" ;;
        *)                     echo "${_a}" ;;
    esac
}

# Resolve which build of an image a given arch must use, into RESOLVED_IMAGE /
# RESOLVED_OPTIONS / RESOLVED_EXEC / RESOLVED_PLATFORMS. docker_images.<img>.
# platforms is flattened to [image_<arch>] by yaml_to_bash.py (and carried into
# users.yaml by setup.sh), so an empty RESOLVED_IMAGE means the image
# declares no build for this arch and must not run here — running it anyway
# dies at `docker run` with "exec format error".
# Usage: resolve_docker_image <image> <arch>
resolve_docker_image() {
    declare -n _ri="DOCKER_${1}"
    RESOLVED_IMAGE="${_ri[image_${2}]:-}"
    RESOLVED_OPTIONS="${_ri[options_${2}]:-${_ri[options]:-}}"
    RESOLVED_EXEC="${_ri[exec_${2}]:-${_ri[exec]:-/bin/bash}}"
    RESOLVED_PLATFORMS="${_ri[platforms]:-}"
    unset -n _ri
}

# Emit a server's git available list (already defaults-merged).
# Usage: server_git_available <server_name>
server_git_available() {
    declare -n _srv="SERVER_${1}"
    local _p
    for _p in ${_srv[git_available_list]}; do echo "$_p"; done
    unset -n _srv
}

# Repo-local git config that makes submodules safe by default. Applied at clone
# time and re-applied idempotently by init.sh, because these are per-clone (a new
# server's fresh clone would otherwise have none of them).
#   push.recurseSubmodules=on-demand — pushing the parent also pushes any submodule
#     commit the parent now points at. Without it a parent can publish a gitlink to
#     a sha no other server can fetch, and their `git submodule update` fails.
#   submodule.recurse=true           — pull/checkout move the submodules too.
#   status.submoduleSummary=true     — `git status` says "1 commit ahead" instead of
#     a bare ` M <path>` that reads like an ordinary file edit.
# A repo with no submodules is untouched (the settings would be inert anyway).
# Mirrored in bash_alias/git.sh `_git_repo_config` (bash_alias sources only
# configuration.sh, not this file) — the two must not drift.
# Usage: apply_repo_git_config <repo_dir> [label]
apply_repo_git_config() {
    local _dir="$1" _label="${2:-$1}"
    [ -d "${_dir}/.git" ] || [ -f "${_dir}/.git" ] || return 0
    [ -f "${_dir}/.gitmodules" ] || return 0
    # Idempotent early-exit: already configured → silent (this runs on every pull)
    [ "$(git -C "${_dir}" config push.recurseSubmodules 2>/dev/null)" = "on-demand" ] && return 0
    git -C "${_dir}" config push.recurseSubmodules on-demand
    git -C "${_dir}" config submodule.recurse true
    git -C "${_dir}" config status.submoduleSummary true
    echo "  [git-config] ${_label} — submodule safety config applied"
}

# Emit a server's docker available list (already defaults-merged).
# Usage: server_docker_available <server_name>
server_docker_available() {
    declare -n _srv="SERVER_${1}"
    local _d
    for _d in ${_srv[docker_available_list]}; do echo "$_d"; done
    unset -n _srv
}

# Membership test against a server's git available list.
# Usage: in_git_available <server_name> <project>
in_git_available() {
    declare -n _srv="SERVER_${1}"
    local _p
    for _p in ${_srv[git_available_list]}; do
        if [ "$_p" = "$2" ]; then unset -n _srv; return 0; fi
    done
    unset -n _srv
    return 1
}

# Membership test against a server's docker available list.
# Usage: in_docker_available <server_name> <image>
in_docker_available() {
    declare -n _srv="SERVER_${1}"
    local _d
    for _d in ${_srv[docker_available_list]}; do
        if [ "$_d" = "$2" ]; then unset -n _srv; return 0; fi
    done
    unset -n _srv
    return 1
}

# Compute the significance (number of leading non-wildcard octets) of an IPv4
# pattern with trailing-zero wildcards. Echoes the count (0..4); echoes -1 if
# the input is not 4 octets.
#   192.168.1.5  → 4 (exact host)
#   192.168.1.0  → 3 (/24)
#   172.18.0.0   → 2 (/16)
#   172.0.0.0    → 1 (/8)
#   0.0.0.0      → 0 (matches everything)
# Usage: ip_pattern_significance <pattern>
ip_pattern_significance() {
    local _pat="$1"
    local -a _p
    IFS='.' read -r -a _p <<< "${_pat}"
    if [ "${#_p[@]}" -ne 4 ]; then echo -1; return; fi
    local _sig=4
    while [ "${_sig}" -gt 0 ] && [ "${_p[$((_sig - 1))]}" = "0" ]; do
        _sig=$((_sig - 1))
    done
    echo "${_sig}"
}

# Octet-aware IP pattern match. The pattern is a 4-octet IPv4 string where
# trailing-zero octets act as wildcards (mid-zero octets are literal). See
# ip_pattern_significance for the wildcard semantics.
#
# Patterns with fewer than 3 significant octets (e.g. 172.0.0.0, 0.0.0.0)
# are rejected — they would match entire /8 or /0 ranges including docker
# bridge interfaces, which historically caused a remote server to be
# mis-identified as local_pc and its working tree wiped by a "local" clone.
# Usage: ip_matches_pattern <pattern> <ip>
ip_matches_pattern() {
    local _pat="$1" _ip="$2"
    local -a _p _l
    IFS='.' read -r -a _p <<< "${_pat}"
    IFS='.' read -r -a _l <<< "${_ip}"
    [ "${#_p[@]}" -ne 4 ] && return 1
    [ "${#_l[@]}" -ne 4 ] && return 1
    local _sig=4
    while [ "${_sig}" -gt 0 ] && [ "${_p[$((_sig - 1))]}" = "0" ]; do
        _sig=$((_sig - 1))
    done
    # Reject too-broad patterns: need /24 or tighter for machine identity
    [ "${_sig}" -lt 3 ] && return 1
    local _i
    for ((_i = 0; _i < _sig; _i++)); do
        [ "${_p[$_i]}" != "${_l[$_i]}" ] && return 1
    done
    return 0
}

# True if the named server matches the local machine.
#
# Delegates to detect_local_server so that the "most specific pattern wins"
# rule applies globally: a wildcard-ish server (e.g. local_pc with ip
# 172.0.0.0) can no longer claim identity just because a docker bridge
# interface matches its /8. Only the single server chosen by
# detect_local_server is treated as local.
#
# Result is cached on first call (detection scans hostname -I, which is
# stable for the lifetime of the process).
# Usage: is_local_server <server_name>
is_local_server() {
    if [ -z "${_IS_LOCAL_SERVER_CACHED:-}" ]; then
        detect_local_server >/dev/null 2>&1 || true
        _IS_LOCAL_SERVER_CACHED=1
    fi
    [ -n "${DETECTED_SERVER}" ] && [ "${DETECTED_SERVER}" = "${1}" ]
}

# ── Push-server membership (project-scoped) ─────────────────────────
# Push permission is project-scoped: a server is a push server FOR A PROJECT
# iff it appears in that project's git_server_allow_push list
# (GIT_SERVER_ALLOW_PUSH_<project>, emitted by yaml_to_bash.py / exec.py).
# There is no server-level allow_push key anymore.
# Usage: is_push_server <server> <project>
is_push_server() {
    local _list_var="GIT_SERVER_ALLOW_PUSH_${2}"
    case " ${!_list_var:-} " in
        *" ${1} "*) return 0 ;;
    esac
    return 1
}

# True if the server is a push server for ANY project — for protective filters
# that have no project context (docker -t all -f, init.sh force gates).
# Usage: is_push_server_any <server>
is_push_server_any() {
    case " ${GIT_SERVER_ALLOW_PUSH_UNION:-} " in
        *" ${1} "*) return 0 ;;
    esac
    return 1
}

# True if the server is a push server for any project that maps this image in
# PROJECT_DOCKER_<p> — decides where an image's _test container belongs.
# Usage: is_push_server_for_image <server> <image>
is_push_server_for_image() {
    local _p _pd_var
    for _p in "${GIT_PROJECT_LIST[@]}"; do
        _pd_var="PROJECT_DOCKER_${_p}"
        case " ${!_pd_var:-} " in
            *" ${2} "*) is_push_server "${1}" "${_p}" && return 0 ;;
        esac
    done
    return 1
}

# Resolve target servers from a -t argument, applying the common selection rule
# and an optional push-server filter.
#
# Common rule (only applied when target == "all"):
#   - server_active_status=true is required for every candidate
#   - if current server has server_remote=false:
#       include = {current} ∪ {servers with server_remote=true}
#   - if current server has server_remote=true:
#       include = {servers with server_remote=true}
#   - if current server cannot be detected: include = {servers with server_remote=true}
#
# Filter:
#   ""        — no extra filter
#   "no_push" — drop push servers. With <project> given, drops servers in that
#               project's git_server_allow_push; without it, drops servers that
#               are a push server for ANY project (union).
#
# For an explicit single-server target, the common rule is NOT applied (the
# user is being explicit), but server_active_status and the push filter
# are still enforced. Unknown / inactive / filtered single targets cause an
# error/skip message on stderr.
#
# Usage: resolve_target_servers <target> [no_push [project]]
# Output: server names, one per line, on stdout
resolve_target_servers() {
    local _target="$1"
    local _filter="${2:-}"
    local _filter_proj="${3:-}"

    # Shared push-filter probe: true → the server must be dropped.
    _rts_push_filtered() {
        [ "${_filter}" != "no_push" ] && return 1
        if [ -n "${_filter_proj}" ]; then
            is_push_server "${1}" "${_filter_proj}"
        else
            is_push_server_any "${1}"
        fi
    }

    # ── Single explicit server ──
    if [ "${_target}" != "all" ]; then
        declare -n _srv="SERVER_${_target}" 2>/dev/null
        if [ ${#_srv[@]} -eq 0 ]; then
            echo "[ERROR] unknown server: ${_target}" >&2
            return 1
        fi
        if [ "${_srv[server_active_status]}" != "true" ]; then
            echo "[SKIP] ${_target} — server_active_status=false" >&2
            unset -n _srv
            return 0
        fi
        if _rts_push_filtered "${_target}"; then
            echo "[SKIP] ${_target} — push server${_filter_proj:+ for '${_filter_proj}'} (excluded by filter)" >&2
            unset -n _srv
            return 0
        fi
        unset -n _srv
        echo "${_target}"
        return 0
    fi

    # ── target == "all": apply common rule ──
    detect_local_server >/dev/null 2>&1 || true
    local _local_remote="true"
    if [ -n "${DETECTED_SERVER}" ]; then
        declare -n _lsrv="SERVER_${DETECTED_SERVER}"
        _local_remote="${_lsrv[server_remote]}"
        unset -n _lsrv
    fi

    local _name
    for _name in "${SERVER_LIST[@]}"; do
        declare -n _srv="SERVER_${_name}"
        [ "${_srv[server_active_status]}" != "true" ] && { unset -n _srv; continue; }

        # Common rule
        if [ "${_local_remote}" = "true" ]; then
            [ "${_srv[server_remote]}" != "true" ] && { unset -n _srv; continue; }
        else
            if [ "${_srv[server_remote]}" != "true" ] && [ "${_name}" != "${DETECTED_SERVER}" ]; then
                unset -n _srv; continue
            fi
        fi

        # Filter
        if _rts_push_filtered "${_name}"; then
            unset -n _srv; continue
        fi

        echo "${_name}"
        unset -n _srv
    done
}

# Validate configuration.sh variables for consistency
# Call after sourcing configuration.sh to check for missing/mismatched definitions.
# Usage: validate_config
validate_config() {
    local _has_error=false

    # Validate: "all" is reserved and cannot be used as a server name
    for _name in "${SERVER_LIST[@]}"; do
        if [ "${_name}" = "all" ]; then
            echo "[configuration.sh] ERROR: 'all' is a reserved name and cannot be used as a server name" >&2
            _has_error=true
        fi
    done

    for _name in "${SERVER_LIST[@]}"; do
        declare -n _ref="SERVER_${_name}" 2>/dev/null
        if [ ${#_ref[@]} -eq 0 ]; then
            echo "[configuration.sh] ERROR: SERVER_${_name} is not defined" >&2
            _has_error=true
            continue
        fi

        local _is_remote="${_ref[server_remote]}"
        local _is_active="${_ref[server_active_status]}"

        # internal_ip is compared literally against `hostname -I` (no wildcard
        # octets — a trailing zero here is a real address), so a full host IP is
        # the only useful form.
        local _int_ip="${_ref[internal_ip]}"
        if [ -n "${_int_ip}" ] && ! [[ "${_int_ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            echo "[configuration.sh] ERROR: SERVER_${_name}[internal_ip]='${_int_ip}' is not in plain IPv4 form (x.x.x.x)" >&2
            _has_error=true
        fi

        if [ "${_is_remote}" = "true" ]; then
            # Remote server → IP is authoritative (used for SSH and identity
            # detection). Must be plain IPv4 dotted form (x.x.x.x).
            # is_local_server interprets it as an octet-aware pattern
            # (trailing-zero octets are wildcards — see
            # ip_pattern_significance); validate_config keeps the form strict
            # so it parses cleanly into 4 octets.
            local _ip_val="${_ref[ip]}"
            if ! [[ "${_ip_val}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                echo "[configuration.sh] ERROR: SERVER_${_name}[ip]='${_ip_val}' is not in plain IPv4 form (x.x.x.x)" >&2
                _has_error=true
            elif [ "${_is_active}" = "true" ]; then
                # Reject too-broad IP patterns (e.g. 172.0.0.0, 0.0.0.0) for
                # active servers. These historically caused is_local_server
                # to mis-identify a remote machine as local_pc because
                # docker bridge IPs (172.x.x.x) fell under the /8 wildcard —
                # triggering a destructive "local" clone on the wrong
                # machine. Require at least 3 significant octets for any
                # server that scripts will actually target.
                local _ip_sig
                _ip_sig=$(ip_pattern_significance "${_ip_val}")
                if [ "${_ip_sig}" -lt 3 ]; then
                    echo "[configuration.sh] ERROR: SERVER_${_name}[ip]='${_ip_val}' is too broad (significance=${_ip_sig}); set at least 3 non-zero octets (e.g. 192.168.1.0 for /24 or a full host IP), or set server_active_status=false" >&2
                    _has_error=true
                fi
            fi
        else
            # Local-only server (server_remote=false) → identified by
            # hostname. WSL/DHCP reassigns the IP on every boot and docker
            # bridges (172.x.x.x) collide with /8 IP patterns, so IP-based
            # matching is unreliable here. hostname is required for active
            # local servers; ip is ignored.
            if [ "${_is_active}" = "true" ] && [ -z "${_ref[hostname]}" ]; then
                echo "[configuration.sh] ERROR: SERVER_${_name}[hostname] is required (server_remote=false, active); set it to the output of \`hostname\` on that machine" >&2
                _has_error=true
            fi
        fi
    done
    unset -n _ref

    for _name in "${DOCKER_LIST[@]}"; do
        declare -n _ref="DOCKER_${_name}" 2>/dev/null
        if [ ${#_ref[@]} -eq 0 ]; then
            echo "[configuration.sh] ERROR: DOCKER_${_name} is not defined" >&2
            _has_error=true
        elif [ -z "${_ref[platforms]:-}" ]; then
            # No platforms → resolve_docker_image returns an empty image for every
            # arch and docker.sh skips the image everywhere, silently.
            echo "[configuration.sh] ERROR: DOCKER_${_name}[platforms] is empty — declare docker_images.${_name}.platforms with at least one platform" >&2
            _has_error=true
        else
            for _plat in ${_ref[platforms]}; do
                if [ -z "${_ref[image_$(docker_arch "${_plat}")]:-}" ]; then
                    echo "[configuration.sh] ERROR: DOCKER_${_name} declares platform '${_plat}' but has no image for it" >&2
                    _has_error=true
                fi
            done
        fi
    done
    unset -n _ref
    unset _plat

    # Per-server docker_available_list must reference defined images.
    for _name in "${SERVER_LIST[@]}"; do
        declare -n _ref="SERVER_${_name}" 2>/dev/null
        for _dock in ${_ref[docker_available_list]}; do
            declare -n _dref="DOCKER_${_dock}" 2>/dev/null
            if [ ${#_dref[@]} -eq 0 ]; then
                echo "[configuration.sh] ERROR: SERVER_${_name}[docker_available_list] references undefined DOCKER_${_dock}" >&2
                _has_error=true
            fi
            unset -n _dref
        done
    done
    unset -n _ref

    # Per-server git_available_list must reference projects in GIT_PROJECT_LIST.
    for _name in "${SERVER_LIST[@]}"; do
        declare -n _ref="SERVER_${_name}" 2>/dev/null
        for _proj in ${_ref[git_available_list]}; do
            if ! is_known_git_project "$_proj"; then
                echo "[configuration.sh] ERROR: SERVER_${_name}[git_available_list] references undefined project '${_proj}'" >&2
                _has_error=true
            fi
        done
    done
    unset -n _ref
    unset _name _dock _proj

    # Validate: PROJECT_DOCKER_{project} defined for every project
    for _proj in "${GIT_PROJECT_LIST[@]}"; do
        local _var="PROJECT_DOCKER_${_proj}"
        if [ -z "${!_var+x}" ]; then
            echo "[configuration.sh] ERROR: PROJECT_DOCKER_${_proj} is not defined (required for project '${_proj}')" >&2
            _has_error=true
        else
            for _img in ${!_var}; do
                if ! is_known_docker_image "$_img"; then
                    echo "[configuration.sh] ERROR: PROJECT_DOCKER_${_proj} references undefined image '${_img}'" >&2
                    _has_error=true
                fi
            done
        fi
    done

    # Validate: GIT_USER_ALLOW_PUSH_{project} defined for every project
    for _proj in "${GIT_PROJECT_LIST[@]}"; do
        local _push_var="GIT_USER_ALLOW_PUSH_${_proj}"
        if [ -z "${!_push_var+x}" ]; then
            echo "[configuration.sh] ERROR: GIT_USER_ALLOW_PUSH_${_proj} is not defined" >&2
            _has_error=true
        elif [ "${!_push_var}" != "true" ] && [ "${!_push_var}" != "false" ]; then
            echo "[configuration.sh] ERROR: GIT_USER_ALLOW_PUSH_${_proj} must be 'true' or 'false', got '${!_push_var}'" >&2
            _has_error=true
        fi
    done

    # Validate: exactly one sync_source=true server
    local _source_count=0
    local _source_servers=""
    for _name in "${SERVER_LIST[@]}"; do
        declare -n _ref="SERVER_${_name}" 2>/dev/null
        if [ "${_ref[sync_hub]}" = "true" ]; then
            _source_count=$((_source_count + 1))
            _source_servers="${_source_servers} ${_name}"
        fi
    done
    unset -n _ref

    if [ "${_source_count}" -eq 0 ]; then
        echo "[configuration.sh] ERROR: no server has sync_hub=true (exactly one required)" >&2
        _has_error=true
    elif [ "${_source_count}" -gt 1 ]; then
        echo "[configuration.sh] ERROR: multiple servers have sync_hub=true:${_source_servers} (exactly one required)" >&2
        _has_error=true
    fi

    if [ "${_has_error}" = true ]; then
        return 1
    fi
    return 0
}

# Detect current server name from hostname (local-only servers) or IP patterns
# (remote servers). Sets globals: DETECTED_SERVER, DETECTED_IP, DETECTED_PORT.
#
# Matching rule:
#   - server_remote=false → exact match against `hostname` command output.
#     IP patterns are meaningless for local-only servers (WSL/DHCP reassigns
#     them on every boot, and docker bridges collide with 172/8).
#   - server_remote=true  → IP pattern match against SSH_CONNECTION IP and
#     `hostname -I` output. Specificity (number of non-wildcard octets) wins
#     among tied IP matches; ties prefer earlier SERVER_LIST entries.
#
# A hostname match always outranks an IP match (local servers are uniquely
# identified by hostname; remote IP matching is only relevant when we're
# actually SSH'd into that remote machine).
# Usage: detect_local_server || exit 1
detect_local_server() {
    local _ssh_ip="" _ssh_port=""
    read -r _ _ _ssh_ip _ssh_port <<< "$SSH_CONNECTION"

    local -a _local_ips=()
    [ -n "${_ssh_ip}" ] && _local_ips+=("${_ssh_ip}")
    local _hi
    for _hi in $(hostname -I); do
        _local_ips+=("$_hi")
    done
    local _my_hostname
    _my_hostname="$(hostname 2>/dev/null)"

    DETECTED_IP=""
    DETECTED_PORT="${_ssh_port:-22}"
    DETECTED_SERVER=""

    # ── Pass 0: machine_id exact match — the only fleet-stable identity ──
    # /etc/machine-id is unique per machine and survives DHCP leases, interface
    # changes and NAT. Hostname (Pass 1) is not unique on cloned images (every
    # Pi answers "raspberrypi"), and internal_ip (Pass 2) moves with the lease.
    local _my_machine_id="" _s0
    [ -r /etc/machine-id ] && _my_machine_id="$(cat /etc/machine-id 2>/dev/null)"
    if [ -n "${_my_machine_id}" ]; then
        for _s0 in "${SERVER_LIST[@]}"; do
            declare -n _srv="SERVER_${_s0}"
            if [ -n "${_srv[machine_id]}" ] \
               && [ "${_srv[machine_id]}" = "${_my_machine_id}" ]; then
                DETECTED_SERVER="${_s0}"
                DETECTED_IP="${_local_ips[0]:-}"
                unset -n _srv
                return 0
            fi
            unset -n _srv
        done
    fi

    # ── Pass 1: hostname match for any server that declares one ──
    # Not gated on server_remote: a NAT'd remote box can never match Pass 3
    # (it only ever sees its private address and the sshd port, never the
    # forwarded ip:port), so hostname is its only non-IP handle.
    local _sname
    for _sname in "${SERVER_LIST[@]}"; do
        declare -n _srv="SERVER_${_sname}"
        if [ -n "${_srv[hostname]}" ] \
           && [ "${_srv[hostname]}" = "${_my_hostname}" ]; then
            DETECTED_SERVER="${_sname}"
            DETECTED_IP="${_local_ips[0]:-}"
            unset -n _srv
            return 0
        fi
        unset -n _srv
    done

    # ── Pass 2: internal_ip exact match (servers behind a port-forward) ──
    # A NAT'd machine cannot see the ip:port the outside reaches it on — it sees
    # its own internal address and the sshd port (22), so Pass 3 never matches.
    # internal_ip is that self-view. It holds a whitespace-separated list, since
    # one machine can sit on two networks (a Pi answers on both its wired 10.0.x
    # and its wireless 192.168.x address) and either one may be the live path.
    local _li _ci
    for _sname in "${SERVER_LIST[@]}"; do
        declare -n _srv="SERVER_${_sname}"
        for _ci in ${_srv[internal_ip]}; do
            for _li in "${_local_ips[@]}"; do
                if [ "${_ci}" = "${_li}" ]; then
                    DETECTED_SERVER="${_sname}"
                    DETECTED_IP="${_li}"
                    unset -n _srv
                    return 0
                fi
            done
        done
        unset -n _srv
    done

    # ── Pass 3: IP pattern match for server_remote=true servers ──
    local _best_sig=-1
    local _best_sname=""
    local _best_ip=""
    local _sig
    for _sname in "${SERVER_LIST[@]}"; do
        declare -n _srv="SERVER_${_sname}"
        [ "${_srv[server_remote]}" != "true" ] && { unset -n _srv; continue; }
        if [ "${_srv[port]}" != "${DETECTED_PORT}" ]; then unset -n _srv; continue; fi
        _sig=$(ip_pattern_significance "${_srv[ip]}")
        # Skip patterns less specific than what we already have (no chance to win)
        if [ "${_sig}" -le "${_best_sig}" ]; then unset -n _srv; continue; fi
        for _li in "${_local_ips[@]}"; do
            if ip_matches_pattern "${_srv[ip]}" "${_li}"; then
                _best_sig="${_sig}"
                _best_sname="${_sname}"
                _best_ip="${_li}"
                break
            fi
        done
        unset -n _srv
    done

    if [ -n "${_best_sname}" ]; then
        DETECTED_SERVER="${_best_sname}"
        DETECTED_IP="${_best_ip}"
        return 0
    fi
    DETECTED_IP="${_ssh_ip:-${_local_ips[0]:-}}"
    return 1
}

# List available projects for the detected server (for help output)
# Usage: list_available_projects
list_available_projects() {
    detect_local_server
    if [ -n "$DETECTED_SERVER" ]; then
        declare -n _ref="SERVER_${DETECTED_SERVER}"
        echo ""
        echo "  Available projects (${DETECTED_SERVER}):"
        for _proj in ${_ref[git_available_list]}; do
            echo "    - ${_proj}"
        done
        unset -n _ref
    else
        echo ""
        echo "  Available projects: (could not detect server)"
    fi
}

# Remove git-cached files that match .gitignore entries
# Usage: clean_gitignored_cache <project_path>
# Scans .gitignore, finds tracked files matching ignore patterns, runs git rm --cached
clean_gitignored_cache() {
    local project_path="$1"
    [ ! -d "${project_path}/.git" ] && return 0
    [ ! -f "${project_path}/.gitignore" ] && return 0

    local files
    files=$(cd "${project_path}" && git ls-files -ci --exclude-standard 2>/dev/null)
    [ -z "${files}" ] && return 0

    echo "  [gitignore-cache] cleaning tracked files matching .gitignore..."
    cd "${project_path}" || return 1
    echo "${files}" | while IFS= read -r f; do
        [ -z "${f}" ] && continue
        git rm --cached "${f}" 2>/dev/null && echo "    rm --cached: ${f}"
    done
    cd - > /dev/null
}
