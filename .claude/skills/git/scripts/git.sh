#!/bin/bash
# ============================================
#  Git — git operations on servers
#
#  Usage (parent project):
#    ./git.sh -a pull  -p <project> -t all
#    ./git.sh -a pull  -p <project> -t <server>
#    ./git.sh -a clone -p <project> -t all     -f
#    ./git.sh -a clone -p <project> -t <server> -f
#    ./git.sh -a push_all -p <project> -m "msg"
#
#  Usage (single submodule of a project — same actions, just add -s):
#    ./git.sh -a pull  -p <project> -s <submodule> -t all
#    ./git.sh -a clone -p <project> -s <submodule> -t <server> -f
#    ./git.sh -a push_all -p <project> -s <submodule> -m "msg"
#
#  Options:
#    -a <action>     pull | clone | push_all (default: pull)
#    -p <project>    target project — required (default + user list)
#    -s <submodule>  scope to a single submodule of -p (must be defined as
#                    SUBMODULE_<project>_<submodule> in configuration.sh).
#                    Without -s the action targets the parent project itself.
#    -t <server>     target server — required for pull/clone ("all" = common rule)
#    -m <message>    commit message for push_all — required
#    -f              clone only: explicit acknowledgement that clone is destructive
#    -h              show help
#
#  Target rules (see utils.sh::resolve_target_servers) — same for parent or sub:
#    pull  -t all          → active O, common remote rule (push servers are
#                            included; the action body downgrades them to
#                            fetch-only and warns)
#    pull  -t <server>     → active O (single server)
#    clone -t all          → active O, common remote rule, allow_push=false only
#    clone -t <server>     → active O, server.allow_push must be false
#    push_all              → current local server only, allow_push=true required.
#                            Parent  → GIT_USER_ALLOW_PUSH_<proj>=true required.
#                            Sub     → SUBMODULE_<p>_<s>[git_user_allow_push]=true required.
#
#  Action semantics (parent or sub — sub just operates inside the submodule's directory):
#    pull  — non-push server, project missing → git clone (parent only — sub
#            requires the parent to already exist; missing parent → SKIP)
#            non-push server, project exists  → git fetch + ff-only pull
#            push server, project exists      → git fetch only, then a loud
#                                                WARNING block if local has
#                                                diverged from origin
#            push server, project missing     → SKIP
#            never destructive
#    clone — always rm -rf + git clone. DESTRUCTIVE.
#            Refuses allow_push=true servers entirely.
#            With -s the rm + clone targets only the submodule directory; the
#            parent working copy is preserved.
#
#  Why push servers are special:
#    They are the user's dev machines. Touching their working copy from
#    automation can hide diverging work or surprise the user with someone
#    else's commits. The pull action therefore downgrades to a fetch-and-
#    warn pattern there, and clone refuses outright. The only automated
#    git operation allowed to mutate a push server is push_all (sending the
#    user's own work upstream).
#
#  Execution:
#    Per target server, runs locally (bash) when the server matches the
#    current machine, otherwise via SSH. chown/rm of root-owned files goes
#    through the base container; the actual git command runs on the host
#    so the forwarded SSH agent reaches github.
#
#  Requires:
#    - "base_{PROJECT_USER}" docker container running on each target server
#    - ssh_forward_agent=true for SSH agent forwarding (github auth)
#    - git installed on each target server
# ============================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
eval "$(python3 "${SCRIPT_DIR}/exec.py" "$(cd "${SCRIPT_DIR}/../../../.." && pwd)/md_files/worklog/users.yaml" "sonny")"
source "${SCRIPT_DIR}/utils.sh"

_show_help() { sed -n '2,/^# ====.*$/p' "$0" | sed 's/^# \?//'; exit 0; }

# Parse options
ACTION="pull"
TARGET_SERVER=""
TARGET_PROJECT=""
TARGET_SUB=""
COMMIT_MSG=""
FORCE=false
SHOW_HELP=false

while getopts "a:p:s:t:m:fh" opt; do
    case $opt in
        a) ACTION="$OPTARG" ;;
        p) TARGET_PROJECT="$OPTARG" ;;
        s) TARGET_SUB="$OPTARG" ;;
        t) TARGET_SERVER="$OPTARG" ;;
        m) COMMIT_MSG="$OPTARG" ;;
        f) FORCE=true ;;
        h) SHOW_HELP=true ;;
        *) echo "Usage: $0 -a <pull|clone|push_all> -p <project> [-s <submodule>] [-t <server|all>] [-m <msg>] [-f] [-h]"; exit 1 ;;
    esac
done

[ "${SHOW_HELP}" = true ] && _show_help

# Validate required options
if [ -z "${TARGET_PROJECT}" ]; then
    echo "[ERROR] -p option required: specify a project"
    exit 1
fi
if [ "${ACTION}" != "pull" ] && [ "${ACTION}" != "clone" ] && [ "${ACTION}" != "push_all" ]; then
    echo "[ERROR] -a must be 'pull', 'clone', or 'push_all'"
    exit 1
fi
if { [ "${ACTION}" = "pull" ] || [ "${ACTION}" = "clone" ]; } && [ -z "${TARGET_SERVER}" ]; then
    echo "[ERROR] -t option required for ${ACTION}: specify a server or 'all'"
    exit 1
fi
if [ "${ACTION}" = "clone" ] && [ "${FORCE}" != true ]; then
    echo "[ERROR] -a clone requires -f (clone is destructive — explicit acknowledgement required)"
    exit 1
fi
if [ "${ACTION}" = "push_all" ] && [ -z "${COMMIT_MSG}" ]; then
    echo "[ERROR] -m option required for push_all: specify a commit message"
    exit 1
fi

# ── -s validation: SUBMODULE_<project>_<sub> must exist ──
SUB_PATH=""
SUB_OWNER=""
SUB_REPO_URL=""
SUB_ALLOW_PUSH=""
if [ -n "${TARGET_SUB}" ]; then
    declare -n _sref="SUBMODULE_${TARGET_PROJECT}_${TARGET_SUB}" 2>/dev/null
    if [ ${#_sref[@]} -eq 0 ]; then
        echo "[ERROR] submodule '${TARGET_SUB}' is not declared under project '${TARGET_PROJECT}'"
        echo "  (looked up SUBMODULE_${TARGET_PROJECT}_${TARGET_SUB})"
        echo "  Available: ${SUBMODULE_LIST[*]:-(none)}"
        exit 1
    fi
    SUB_PATH="${_sref[path]}"
    SUB_OWNER="${_sref[git_owner]}"
    SUB_ALLOW_PUSH="${_sref[git_user_allow_push]}"
    SUB_REPO_URL="git@github.com:${SUB_OWNER}/${TARGET_SUB}.git"
    unset -n _sref
fi

# Ensure SSH agent is running and key is loaded (required for -A forwarding)
ensure_ssh_agent || exit 1

# Get base docker target_mnt_path (for chown/rm inside container)
declare -n _base_img="DOCKER_base"
BASE_TARGET="${_base_img[target_mnt_path]}"
unset -n _base_img

# ── push_all: current server only ────────────────────────────────────

if [ "${ACTION}" = "push_all" ]; then
    detect_local_server || { echo "[ERROR] Could not detect current server"; exit 1; }
    LOCAL_SERVER="$DETECTED_SERVER"

    declare -n srv="SERVER_${LOCAL_SERVER}"

    # Server must allow push
    if [ "${srv[allow_push]}" != "true" ]; then
        echo "[ERROR] git push not available on ${LOCAL_SERVER} (server allow_push=false)"
        unset -n srv
        exit 1
    fi

    # Parent project must be in this server's combined available list
    if ! in_git_available "${LOCAL_SERVER}" "${TARGET_PROJECT}"; then
        echo "[ERROR] '${TARGET_PROJECT}' not in git available list for ${LOCAL_SERVER}"
        unset -n srv
        exit 1
    fi

    # Per-(project|submodule) push permission gate
    if [ -n "${TARGET_SUB}" ]; then
        if [ "${SUB_ALLOW_PUSH}" != "true" ]; then
            echo "[ERROR] git push not allowed for submodule '${TARGET_SUB}' of '${TARGET_PROJECT}' (git_user_allow_push=false)"
            unset -n srv
            exit 1
        fi
    else
        _proj_push_var="GIT_USER_ALLOW_PUSH_${TARGET_PROJECT}"
        if [ "${!_proj_push_var}" = "false" ]; then
            echo "[ERROR] git push not allowed for project '${TARGET_PROJECT}' (git_user_allow_push=false)"
            unset -n srv
            exit 1
        fi
    fi

    src_vol="${srv[source_mnt_path]}"
    if [ -n "${TARGET_SUB}" ]; then
        host_path="${src_vol}/${TARGET_PROJECT}/${SUB_PATH}"
        docker_path="${BASE_TARGET}/${TARGET_PROJECT}/${SUB_PATH}"
        repo_url="${SUB_REPO_URL}"
        _label="${TARGET_PROJECT}/${TARGET_SUB}"
    else
        host_path="${src_vol}/${TARGET_PROJECT}"
        docker_path="${BASE_TARGET}/${TARGET_PROJECT}"
        _owner_var="GIT_OWNER_${TARGET_PROJECT}"
        repo_url="git@github.com:${!_owner_var}/${TARGET_PROJECT}.git"
        _label="${TARGET_PROJECT}"
    fi

    if [ ! -d "${host_path}" ]; then
        echo "[ERROR] directory not found: ${host_path}"
        unset -n srv
        exit 1
    fi

    echo "=================================="
    echo "[${LOCAL_SERVER}] push_all: ${_label}"
    echo "=================================="

    # Ensure base container is running
    ensure_base "${LOCAL_SERVER}" "${SCRIPT_DIR}" || { unset -n srv; exit 1; }

    # chown so host user can write
    echo "  [chown] ${_label}"
    docker exec ${BASE_CONTAINER} chown -R "$(id -u):$(id -g)" "${docker_path}"

    cd "${host_path}" || { unset -n srv; exit 1; }
    export GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null'

    # Only the parent gets the gitignore cache cleanup; submodule has its own
    # gitignore handling and we don't want to surprise it.
    [ -z "${TARGET_SUB}" ] && clean_gitignored_cache "${host_path}"

    echo "  [add] ${_label}"
    git add .

    echo "  [commit] ${_label} — \"${COMMIT_MSG}\""
    git commit -m "${COMMIT_MSG}"

    echo "  [push] ${_label}"
    git push "${repo_url}"

    cd - > /dev/null
    unset -n srv
    echo ""
    echo "[push_all] complete"
    exit 0
fi

# ── pull / clone: resolve targets ──
# clone drops allow_push=true servers entirely (destructive on dev machine
# is too dangerous). pull keeps them in the list — the action body downgrades
# them to a fetch-and-warn pattern so the user notices drift.
if [ "${TARGET_SERVER}" = "all" ]; then
    if [ "${ACTION}" = "clone" ]; then
        _targets=$(resolve_target_servers all no_push) || exit 1
    else
        _targets=$(resolve_target_servers all) || exit 1
    fi
else
    _targets=$(resolve_target_servers "${TARGET_SERVER}") || exit 1
fi

if [ -z "${_targets}" ]; then
    echo "[INFO] no eligible target servers"
    exit 0
fi

# Read the target list from fd 3 instead of stdin so any subprocess in the
# loop body (notably ssh) cannot consume the remaining server names.
while IFS= read -r name <&3; do
    [ -z "${name}" ] && continue
    declare -n srv="SERVER_${name}"

    # Project must be in combined available list for this server
    if ! in_git_available "${name}" "${TARGET_PROJECT}"; then
        echo "[SKIP] ${name} — '${TARGET_PROJECT}' not in git available list"
        unset -n srv
        continue
    fi

    # allow_push=true servers are user-developed machines. We never modify
    # their working copy automatically:
    #   clone -f → SKIP entirely (destructive, would erase uncommitted work)
    #   pull    → fetch only, then loudly WARN the user if local has diverged
    #             from origin so they can sync by hand. The actual pull is
    #             never run.
    if [ "${ACTION}" = "clone" ] && [ "${srv[allow_push]}" = "true" ]; then
        echo "[SKIP] ${name} — allow_push=true (clone refuses; handle manually via ssh)"
        unset -n srv
        continue
    fi

    echo "=================================="
    echo "[${name}] ${srv[ip]}:${srv[port]}"
    echo "=================================="

    # Ensure base container is running (auto-start if needed)
    ensure_base "${name}" "${SCRIPT_DIR}" || { unset -n srv; continue; }

    port_opt=""
    [ "${srv[port]}" != "22" ] && [ -n "${srv[port]}" ] && port_opt="-p ${srv[port]}"

    key_opt=""
    [ -n "${srv[ssh_key]}" ] && key_opt="-i ${srv[ssh_key]}"

    # -A for SSH agent forwarding (github auth via forwarded key)
    agent_opt=""
    [ "${srv[ssh_forward_agent]}" = "true" ] && agent_opt="-A"

    user="${srv[ssh_user]}"
    src_vol="${srv[source_mnt_path]}"

    # Build remote commands — git on host, chown/rm via docker exec ${BASE_CONTAINER}
    remote_cmds=""

    # Auto-accept github.com host key (avoids known_hosts write permission issues)
    remote_cmds="${remote_cmds}export GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null'; "

    # Resolve target paths and labels — parent vs submodule scope
    if [ -n "${TARGET_SUB}" ]; then
        # Submodule scope
        host_path="${src_vol}/${TARGET_PROJECT}/${SUB_PATH}"
        docker_path="${BASE_TARGET}/${TARGET_PROJECT}/${SUB_PATH}"
        parent_host_path="${src_vol}/${TARGET_PROJECT}"
        repo_url="${SUB_REPO_URL}"
        _label="${TARGET_PROJECT}/${TARGET_SUB}"
        _clone_opts=""
        _has_subs=false
    else
        # Parent scope — recurse into any nested submodules
        _sub_list_var="GIT_SUBMODULES_${TARGET_PROJECT}"
        _has_subs=false
        [ -n "${!_sub_list_var:-}" ] && _has_subs=true
        _clone_opts=""
        [ "${_has_subs}" = true ] && _clone_opts="--recurse-submodules"

        _owner_var="GIT_OWNER_${TARGET_PROJECT}"
        repo_url="git@github.com:${!_owner_var}/${TARGET_PROJECT}.git"
        host_path="${src_vol}/${TARGET_PROJECT}"
        docker_path="${BASE_TARGET}/${TARGET_PROJECT}"
        parent_host_path=""
        _label="${TARGET_PROJECT}"
    fi

    if [ "${ACTION}" = "clone" ]; then
        if [ -n "${TARGET_SUB}" ]; then
            # submodule clone: parent must already exist (we never create
            # parents in sub-mode). rm only the submodule directory then
            # restore it via `git submodule update --init` on the parent so
            # gitlink + .git/modules stay consistent.
            remote_cmds="${remote_cmds}if [ ! -d ${parent_host_path} ]; then echo '  [SKIP] parent ${TARGET_PROJECT} missing — cannot clone submodule'; "
            remote_cmds="${remote_cmds}else "
            remote_cmds="${remote_cmds}echo '  [rm] ${_label}'; docker exec ${BASE_CONTAINER} rm -rf ${docker_path}; "
            remote_cmds="${remote_cmds}docker exec ${BASE_CONTAINER} chown -R \$(id -u):\$(id -g) ${BASE_TARGET}/${TARGET_PROJECT}; "
            remote_cmds="${remote_cmds}cd ${parent_host_path} && rm -rf .git/modules/${TARGET_SUB} 2>/dev/null; "
            remote_cmds="${remote_cmds}echo '  [submodule update --init] ${_label}'; git submodule update --init -- ${SUB_PATH}; "
            remote_cmds="${remote_cmds}cd - > /dev/null; "
            remote_cmds="${remote_cmds}fi; "
        else
            # parent clone: rm (via docker, root files) + chown parent dir + clone
            remote_cmds="${remote_cmds}echo '  [rm] ${_label}'; docker exec ${BASE_CONTAINER} rm -rf ${docker_path}; "
            remote_cmds="${remote_cmds}docker exec ${BASE_CONTAINER} chown -R \$(id -u):\$(id -g) ${docker_path%/*}; "
            remote_cmds="${remote_cmds}mkdir -p ${src_vol}; "
            remote_cmds="${remote_cmds}echo '  [clone] ${_label}'; git clone ${_clone_opts} ${repo_url} ${host_path}; "
        fi
    elif [ "${srv[allow_push]}" = "true" ]; then
        # pull on a push server: never modify the working copy. Fetch only,
        # then loudly warn if local has diverged from origin (or has
        # uncommitted changes). Same behaviour for parent or submodule —
        # the cwd is just whichever directory we're scoped to.
        remote_cmds="${remote_cmds}if [ -d ${host_path} ]; then "
        remote_cmds="${remote_cmds}docker exec ${BASE_CONTAINER} chown -R \$(id -u):\$(id -g) ${docker_path}; "
        remote_cmds="${remote_cmds}cd ${host_path}; "
        remote_cmds="${remote_cmds}echo '  [fetch] ${_label} (push server — fetch only, no working-copy changes)'; "
        remote_cmds="${remote_cmds}_fetch_ok=true; git fetch origin 2>/dev/null || _fetch_ok=false; "
        remote_cmds="${remote_cmds}_branch=\$(git rev-parse --abbrev-ref HEAD 2>/dev/null); "
        remote_cmds="${remote_cmds}_dirty=\$(git status --porcelain 2>/dev/null | wc -l); "
        remote_cmds="${remote_cmds}_counts=\$(git rev-list --left-right --count HEAD...@{upstream} 2>/dev/null); "
        remote_cmds="${remote_cmds}_ahead=\$(echo \"\${_counts}\" | awk '{print \$1}'); "
        remote_cmds="${remote_cmds}_behind=\$(echo \"\${_counts}\" | awk '{print \$2}'); "
        remote_cmds="${remote_cmds}_ahead=\${_ahead:-0}; _behind=\${_behind:-0}; "
        remote_cmds="${remote_cmds}if [ \"\${_ahead}\" != 0 ] || [ \"\${_behind}\" != 0 ] || [ \"\${_dirty}\" -gt 0 ]; then "
        remote_cmds="${remote_cmds}echo ''; "
        remote_cmds="${remote_cmds}echo '  ============================================================'; "
        remote_cmds="${remote_cmds}echo '  [WARNING] ${_label} on ${name} (allow_push=true) is OUT OF SYNC'; "
        remote_cmds="${remote_cmds}echo \"             branch=\${_branch}  ahead=\${_ahead}  behind=\${_behind}  uncommitted=\${_dirty}\"; "
        remote_cmds="${remote_cmds}[ \"\${_fetch_ok}\" != true ] && echo '             (fetch failed — comparing against last cached origin state)'; "
        remote_cmds="${remote_cmds}echo '             auto-pull was skipped to preserve your work.'; "
        remote_cmds="${remote_cmds}echo '             Resolve manually:'; "
        remote_cmds="${remote_cmds}echo '               cd ${host_path}'; "
        remote_cmds="${remote_cmds}echo '               git status'; "
        remote_cmds="${remote_cmds}echo '               git pull     # or rebase / push_all as appropriate'; "
        remote_cmds="${remote_cmds}echo '  ============================================================'; "
        remote_cmds="${remote_cmds}echo ''; "
        remote_cmds="${remote_cmds}else "
        remote_cmds="${remote_cmds}echo '  [ok] ${_label} — clean and up to date with origin'; "
        remote_cmds="${remote_cmds}fi; "
        remote_cmds="${remote_cmds}cd - > /dev/null; "
        remote_cmds="${remote_cmds}else "
        remote_cmds="${remote_cmds}echo '  [SKIP] ${_label} — directory missing on push server (clone manually)'; "
        remote_cmds="${remote_cmds}fi; "
    else
        # pull on a non-push server.
        # parent: clone if missing, ff-only pull if exists.
        # sub:    require parent to exist (no auto-clone of parent in sub-mode);
        #         then ff-only pull inside the submodule directory.
        if [ -n "${TARGET_SUB}" ]; then
            remote_cmds="${remote_cmds}if [ ! -d ${parent_host_path} ]; then "
            remote_cmds="${remote_cmds}echo '  [SKIP] parent ${TARGET_PROJECT} missing — clone parent first'; "
            remote_cmds="${remote_cmds}elif [ ! -d ${host_path}/.git ] && [ ! -f ${host_path}/.git ]; then "
            remote_cmds="${remote_cmds}echo '  [submodule update --init] ${_label}'; "
            remote_cmds="${remote_cmds}docker exec ${BASE_CONTAINER} chown -R \$(id -u):\$(id -g) ${BASE_TARGET}/${TARGET_PROJECT}; "
            remote_cmds="${remote_cmds}cd ${parent_host_path} && git submodule update --init -- ${SUB_PATH}; cd - > /dev/null; "
            remote_cmds="${remote_cmds}else "
            remote_cmds="${remote_cmds}docker exec ${BASE_CONTAINER} chown -R \$(id -u):\$(id -g) ${docker_path}; "
            remote_cmds="${remote_cmds}echo '  [fetch] ${_label}'; cd ${host_path} && git fetch origin; "
            remote_cmds="${remote_cmds}if git merge-base --is-ancestor HEAD FETCH_HEAD 2>/dev/null; then "
            remote_cmds="${remote_cmds}echo '  [pull] ${_label}'; git pull --ff-only; "
            remote_cmds="${remote_cmds}else echo '  [ERROR] ${_label}: not fast-forward, pull skipped (resolve manually)'; fi; "
            remote_cmds="${remote_cmds}cd - > /dev/null; "
            remote_cmds="${remote_cmds}fi; "
        else
            remote_cmds="${remote_cmds}if [ -d ${host_path} ]; then "
            remote_cmds="${remote_cmds}docker exec ${BASE_CONTAINER} chown -R \$(id -u):\$(id -g) ${docker_path}; "
            remote_cmds="${remote_cmds}echo '  [fetch] ${_label}'; cd ${host_path} && git fetch origin; "
            remote_cmds="${remote_cmds}if git merge-base --is-ancestor HEAD FETCH_HEAD; then "
            remote_cmds="${remote_cmds}echo '  [pull] ${_label}'; git pull --ff-only; "
            if [ "${_has_subs}" = true ]; then
                remote_cmds="${remote_cmds}echo '  [submodule] ${_label}'; git submodule update --init --recursive; "
            fi
            remote_cmds="${remote_cmds}else echo '  [ERROR] ${_label}: not fast-forward, pull skipped (resolve manually)'; fi; "
            remote_cmds="${remote_cmds}cd - > /dev/null; "
            remote_cmds="${remote_cmds}else "
            remote_cmds="${remote_cmds}docker exec ${BASE_CONTAINER} chown -R \$(id -u):\$(id -g) ${docker_path%/*}; "
            remote_cmds="${remote_cmds}mkdir -p ${src_vol}; "
            remote_cmds="${remote_cmds}echo '  [clone] ${_label}'; git clone ${_clone_opts} ${repo_url} ${host_path}; fi; "
        fi
    fi

    # bash if current machine, otherwise SSH. We do NOT pass -t to ssh:
    # forcing a pseudo-tty makes ssh consume the outer while-read loop's
    # stdin (the heredoc), and only the first server gets processed. git
    # commands here are non-interactive so a tty is unnecessary.
    if is_local_server "${name}"; then
        bash -c "${remote_cmds}"
    else
        ssh ${agent_opt} ${port_opt} ${key_opt} ${user}@${srv[ip]} "${remote_cmds}" < /dev/null
    fi
    unset -n srv
    echo ""
done 3<<< "${_targets}"
