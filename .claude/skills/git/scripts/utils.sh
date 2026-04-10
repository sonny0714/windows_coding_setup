#!/bin/bash
# ============================================
#  Exec utilities — shared functions for exec/ scripts
# ============================================

# Derived from configuration.sh
BASE_CONTAINER="base_${PROJECT_USER}"

# Build SSH options from server config
# Usage: ssh_opts=$(build_ssh_opts "$name")
build_ssh_opts() {
    local name="$1"
    declare -n _srv="SERVER_${name}"
    local opts=""
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
        ssh ${opts} ${user}@${ip} "${cmd}" 2>/dev/null
    fi
}

# Ensure base container is running on server
# If stopped → docker start, if not found → docker.sh -i base -t <server>
# Usage: ensure_base "$name" "$SCRIPT_DIR"
ensure_base() {
    local name="$1"
    local script_dir="$2"
    local cname="base_${PROJECT_USER}"

    # Check if base is running
    local is_running
    is_running=$(run_on_server "$name" "docker ps --format '{{.Names}}' | grep -qx '${cname}' && echo yes")
    [ "${is_running}" = "yes" ] && return 0

    # Try start (stopped container) or create (no container)
    local result
    result=$(run_on_server "$name" "if docker ps -a --format '{{.Names}}' | grep -qx '${cname}'; then echo '  [${cname}] stopped, restarting...'; docker start ${cname} >/dev/null; else echo '  [${cname}] not found, creating...'; fi")
    echo "${result}"

    if echo "${result}" | grep -q "not found"; then
        "${script_dir}/docker.sh" -i base -t "${name}"
    fi

    # Verify
    is_running=$(run_on_server "$name" "docker ps --format '{{.Names}}' | grep -qx '${cname}' && echo yes")
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
#  Shared across exec/*.sh — single source of truth for "what is a valid
#  target?" and "is this project/image available on this server?"
#
#  Defaults (from configuration_default.yaml) are merged into GIT_PROJECT_LIST,
#  DOCKER_LIST, and every server's git_available_list / docker_available_list
#  by yaml_to_bash.py and worklog_setup.sh, so the helpers below treat all
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

# Emit a server's git available list (already defaults-merged).
# Usage: server_git_available <server_name>
server_git_available() {
    declare -n _srv="SERVER_${1}"
    local _p
    for _p in ${_srv[git_available_list]}; do echo "$_p"; done
    unset -n _srv
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
    local _i
    for ((_i = 0; _i < _sig; _i++)); do
        [ "${_p[$_i]}" != "${_l[$_i]}" ] && return 1
    done
    return 0
}

# True if the named server matches the local machine. We test the server's
# configured ip (interpreted by ip_matches_pattern — trailing zeros are
# wildcards) against every IP advertised by `hostname -I`. Returns success
# as soon as any host IP matches.
# Usage: is_local_server <server_name>
is_local_server() {
    declare -n _srv="SERVER_${1}"
    local _pat="${_srv[ip]}"
    unset -n _srv
    local _local
    for _local in $(hostname -I); do
        ip_matches_pattern "${_pat}" "${_local}" && return 0
    done
    return 1
}

# Resolve target servers from a -t argument, applying the common selection rule
# and an optional allow_push filter.
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
#   "no_push" — drop servers with allow_push=true
#
# For an explicit single-server target, the common rule is NOT applied (the
# user is being explicit), but server_active_status and the allow_push filter
# are still enforced. Unknown / inactive / filtered single targets cause an
# error/skip message on stderr.
#
# Usage: resolve_target_servers <target> [no_push]
# Output: server names, one per line, on stdout
resolve_target_servers() {
    local _target="$1"
    local _filter="${2:-}"

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
        if [ "${_filter}" = "no_push" ] && [ "${_srv[allow_push]}" = "true" ]; then
            echo "[SKIP] ${_target} — allow_push=true (excluded by filter)" >&2
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
        if [ "${_filter}" = "no_push" ] && [ "${_srv[allow_push]}" = "true" ]; then
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
        # IP must be plain IPv4 dotted form (x.x.x.x). is_local_server
        # interprets it as an octet-aware pattern (trailing-zero octets are
        # wildcards — see ip_pattern_significance). validate_config keeps the
        # form strict so it parses cleanly into 4 octets.
        local _ip_val="${_ref[ip]}"
        if ! [[ "${_ip_val}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            echo "[configuration.sh] ERROR: SERVER_${_name}[ip]='${_ip_val}' is not in plain IPv4 form (x.x.x.x)" >&2
            _has_error=true
        fi
    done
    unset -n _ref

    for _name in "${DOCKER_LIST[@]}"; do
        declare -n _ref="DOCKER_${_name}" 2>/dev/null
        if [ ${#_ref[@]} -eq 0 ]; then
            echo "[configuration.sh] ERROR: DOCKER_${_name} is not defined" >&2
            _has_error=true
        fi
    done
    unset -n _ref

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

# Detect current server name from SSH_CONNECTION (preferred) or hostname IPs.
# Sets globals: DETECTED_SERVER, DETECTED_IP, DETECTED_PORT.
#
# When multiple servers' ip patterns happen to match the same local interface
# (typical case: an exact-host server like deep [ip=115.145.178.111] AND a
# wildcard server like local_pc [ip=172.0.0.0] both match a machine that
# has docker bridge 172.x.x.x interfaces), the *most specific* pattern wins.
# Specificity is the number of leading non-wildcard octets (significance).
# Ties prefer earlier entries in SERVER_LIST.
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

    DETECTED_IP=""
    DETECTED_PORT="${_ssh_port:-22}"
    DETECTED_SERVER=""

    local _best_sig=-1
    local _best_sname=""
    local _best_ip=""
    local _sname _li _sig
    for _sname in "${SERVER_LIST[@]}"; do
        declare -n _srv="SERVER_${_sname}"
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
