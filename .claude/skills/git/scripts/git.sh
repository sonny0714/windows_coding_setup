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
#    ./git.sh -a push_all -p <project> -m "msg" -b <branch>
#
#  Usage (single submodule of a project — same actions, just add -s):
#    ./git.sh -a pull  -p <project> -s <submodule> -t all
#    ./git.sh -a clone -p <project> -s <submodule> -t <server> -f
#    ./git.sh -a push_all -p <project> -s <submodule> -m "msg" [-b <branch>]
#                             ^ pushes the submodule AND records the new pointer in
#                               the parent (add gitlink + commit + push). Add -N to
#                               skip that and leave the parent on the old sha —
#                               which means the submodule change never enters the
#                               parent's history.
#
#  Options:
#    -a <action>     pull | clone | push_all (default: pull)
#    -p <project>    target project — required (default + user list)
#    -s <submodule>  scope to a single submodule of -p (must be defined as
#                    SUBMODULE_<project>_<submodule> in configuration.sh).
#                    Without -s the action targets the parent project itself.
#    -t <server>     target server — required for pull/clone ("all" = common rule)
#    -m <message>    commit message for push_all — required
#    -b <branch>     push_all only: push HEAD to this remote branch (git push
#                    <url> HEAD:<branch>). Omit → git push <url> (current branch).
#    -N              push_all -s only: do NOT bump the parent's gitlink afterwards.
#                    The bump is the default because leaving the parent on the old
#                    sha is the mistake, not the intent; it is safe by default
#                    because it runs only after the push succeeded and re-checks
#                    that the sha is on a remote branch.
#    -f              clone only: explicit acknowledgement that clone is destructive
#    -h              show help
#
#  Target rules (see utils.sh::resolve_target_servers) — same for parent or sub:
#    pull  -t all          → active O, common remote rule (push servers are
#                            included; the action body downgrades them to
#                            fetch-only and warns)
#    pull  -t <server>     → active O (single server)
#    clone -t all          → active O, common remote rule, drops the project's
#                            git_server_allow_push servers
#    clone -t <server>     → active O, server must NOT be in the project's
#                            git_server_allow_push
#    push_all              → current local server only, server must be in the
#                            project's git_server_allow_push.
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
#            Refuses the project's push servers entirely.
#            With -s the rm + clone targets only the submodule directory; the
#            parent working copy is preserved.
#
#  Why push servers are special:
#    A project's git_server_allow_push servers are where the user develops
#    that project. Touching their working copy from automation can hide
#    diverging work or surprise the user with someone else's commits. The
#    pull action therefore downgrades to a fetch-and-warn pattern there, and
#    clone refuses outright. The only automated git operation allowed to
#    mutate a push server is push_all (sending the user's own work upstream).
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
eval "$(python3 "${SCRIPT_DIR}/exec.py" "$(cd "${SCRIPT_DIR}/../../../.." && pwd)/md_files/users/users.yaml" "sonny")"
source "${SCRIPT_DIR}/utils.sh"

_show_help() { sed -n '2,/^# ====.*$/p' "$0" | sed 's/^# \?//'; exit 0; }

# Refresh refs/remotes/* after a successful push. Our pushes target a raw URL
# (repo_url / _parent_url), and git updates a remote-tracking ref only for a
# named remote — without this the branch reads "ahead N" forever and the
# `git log @{u}..HEAD` count below over-reports. No origin remote → no tracking
# ref to refresh; a failed fetch never demotes the push that already landed.
# Mirrored in bash_alias/git.sh — the two must not drift.
#   Usage: _git_sync_tracking <work_path>
_git_sync_tracking() {
    local _work="$1"
    git -C "${_work}" remote get-url origin > /dev/null 2>&1 || return 0
    git -C "${_work}" fetch -q origin \
        || echo "  [WARN] ${_work}: remote-tracking refs not refreshed — 'ahead N' may read stale"
    return 0
}

# Parse options
ACTION="pull"
TARGET_SERVER=""
TARGET_PROJECT=""
TARGET_SUB=""
COMMIT_MSG=""
PUSH_BRANCH=""
FORCE=false
THEN_BUMP=true
SHOW_HELP=false

while getopts "a:p:s:t:m:b:Nfh" opt; do
    case $opt in
        a) ACTION="$OPTARG" ;;
        p) TARGET_PROJECT="$OPTARG" ;;
        s) TARGET_SUB="$OPTARG" ;;
        t) TARGET_SERVER="$OPTARG" ;;
        m) COMMIT_MSG="$OPTARG" ;;
        b) PUSH_BRANCH="$OPTARG" ;;
        N) THEN_BUMP=false ;;
        f) FORCE=true ;;
        h) SHOW_HELP=true ;;
        *) echo "Usage: $0 -a <pull|clone|push_all> -p <project> [-s <submodule>] [-t <server|all>] [-m <msg>] [-b <branch>] [-N] [-f] [-h]"; exit 1 ;;
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
SUB_PUSH_SERVER_ONLY=""
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
    SUB_PUSH_SERVER_ONLY="${_sref[active_pull_if_allow_push_server]}"
    SUB_REPO_URL="git@github.com:${SUB_OWNER}/${TARGET_SUB}.git"
    unset -n _sref
    # Guard against empty path — otherwise clone's rm -rf would target the
    # parent project directory (see past clone-wipes-project incident).
    if [ -z "${SUB_PATH}" ] || [[ "${SUB_PATH}" = /* ]]; then
        echo "[ERROR] submodule '${TARGET_SUB}' of '${TARGET_PROJECT}' has invalid path: '${SUB_PATH}'"
        echo "  path must be non-empty and relative to the parent project root"
        exit 1
    fi
fi

# Ensure SSH agent is running and key is loaded (required for -A forwarding)
ensure_ssh_agent || exit 1

# Get base docker target_mnt_path (for chown/rm inside container)
declare -n _base_img="DOCKER_base"
BASE_TARGET="${_base_img[target_mnt_path]}"
unset -n _base_img
# Guard: BASE_TARGET must be an absolute, non-root path — destructive rm
# inside the base container relies on it.
if [ -z "${BASE_TARGET}" ] || [ "${BASE_TARGET}" = "/" ]; then
    echo "[ERROR] DOCKER_base[target_mnt_path] is empty or '/' — refusing to run"
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════
# ACTION: push_all — commit + push from current server only
# ═══════════════════════════════════════════════════════════════════

if [ "${ACTION}" = "push_all" ]; then
    detect_local_server || { echo "[ERROR] Could not detect current server"; exit 1; }
    LOCAL_SERVER="$DETECTED_SERVER"

    declare -n srv="SERVER_${LOCAL_SERVER}"

    # Server must be in the project's push-server list
    if ! is_push_server "${LOCAL_SERVER}" "${TARGET_PROJECT}"; then
        echo "[ERROR] git push not available on ${LOCAL_SERVER} — not in git_server_allow_push for '${TARGET_PROJECT}'"
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

    print_banner_line "[${LOCAL_SERVER}] push_all: ${_label}"

    # Ensure base container is running
    ensure_base "${LOCAL_SERVER}" || { unset -n srv; exit 1; }

    # chown so host user can write
    echo "  [chown] ${_label}"
    docker exec ${BASE_CONTAINER} chown -R "$(id -u):$(id -g)" "${docker_path}"

    cd "${host_path}" || { unset -n srv; exit 1; }
    export GIT_SSH_COMMAND='ssh -p 22 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null'

    # Only the parent gets the gitignore cache cleanup; submodule has its own
    # gitignore handling and we don't want to surprise it.
    [ -z "${TARGET_SUB}" ] && clean_gitignored_cache "${host_path}"

    # Parent scope: keep every submodule gitlink (disabled ones too) out of
    # `git add .`. Staging a moved pointer here would publish a submodule commit
    # that may never have been pushed, and every other server then fails
    # `git submodule update` on the missing sha. Bumping stays a deliberate act.
    _add_excl=""
    if [ -z "${TARGET_SUB}" ]; then
        _sub_list_var="GIT_SUBMODULES_${TARGET_PROJECT}"
        _dsub_list_var="GIT_SUBMODULES_DISABLED_${TARGET_PROJECT}"
        for _sn in ${!_sub_list_var:-} ${!_dsub_list_var:-}; do
            declare -n _sxref="SUBMODULE_${TARGET_PROJECT}_${_sn}"
            _add_excl="${_add_excl}:!${_sxref[path]} "
            unset -n _sxref
        done
    fi

    echo "  [add] ${_label}"
    git add . ${_add_excl}
    if [ -n "${_add_excl}" ]; then
        _moved="$(git diff --name-only -- ${_add_excl//:!/} 2>/dev/null)"
        [ -n "${_moved}" ] && {
            echo "  [note] submodule pointer not staged (moved: ${_moved//$'\n'/ })"
            echo "         record it with: $0 -a push_all -p ${TARGET_PROJECT} -s <submodule> -m \"msg\""
        }
    fi

    # _prc accumulates this action's failures. Every failing step prints an
    # [ERROR] line naming itself — a push that fails must never scroll past as
    # if it landed, and the final verdict/exit code must reflect it.
    # Index-only check: commit commits the INDEX, so "nothing to commit" is
    # exactly "nothing staged". Testing the working tree too would mis-route the
    # routine excluded-gitlink-moved state (staged empty, tree dirty) into the
    # commit branch, where `git commit` fails and gets promoted to [ERROR].
    _prc=0
    if git diff --cached --quiet; then
        echo "  [note] ${_label} — nothing staged to commit"
    else
        echo "  [commit] ${_label} — \"${COMMIT_MSG}\""
        git commit -m "${COMMIT_MSG}" || { echo "[ERROR] commit failed for ${_label}"; _prc=1; }
    fi

    if [ "${_prc}" -eq 0 ]; then
        if [ -n "${PUSH_BRANCH}" ]; then
            echo "  [push] ${_label} → HEAD:${PUSH_BRANCH}"
            git push "${repo_url}" "HEAD:${PUSH_BRANCH}" || { _prc=1; echo "[ERROR] push failed for ${_label} → HEAD:${PUSH_BRANCH}"; }
        else
            echo "  [push] ${_label}"
            git push "${repo_url}" || { _prc=1; echo "[ERROR] push failed for ${_label}"; }
        fi
        [ "${_prc}" -eq 0 ] && _git_sync_tracking "${host_path}"
    fi

    # Record the pointer the submodule now sits at, in the parent — the second half
    # people forget, which leaves the parent on the old sha so the submodule change
    # never enters the parent's history. Default ON; -N opts out.
    # The `--contains HEAD` probe is what makes staging safe: it proves the sha is
    # fetchable, which is the exact accident the blanket exclusion above avoids.
    # Everything that is not "the pointer moved and can be recorded" is a NOTE, not
    # a failure — the submodule push already succeeded and must not be reported red.
    if [ "${THEN_BUMP}" = true ] && [ -n "${TARGET_SUB}" ] && [ "${_prc}" -eq 0 ]; then
        _parent_push_var="GIT_USER_ALLOW_PUSH_${TARGET_PROJECT}"
        _parent_path="${src_vol}/${TARGET_PROJECT}"
        if [ "${!_parent_push_var}" = "false" ]; then
            _sha_ok=skip
            echo "  [note] parent '${TARGET_PROJECT}' pointer NOT recorded (git_user_allow_push=false)"
        else
            # Fetchability probe, three steps cheapest-first. Step 2's fetch is
            # REQUIRED: the push above went to a raw URL, and a URL push does NOT
            # update refs/remotes/*, so right after a successful push step 1 alone
            # still says "not on any remote". Step 3 covers a repo whose remote is
            # not `origin`. Mirrored in bash_alias/git.sh `_git_sha_on_remote` —
            # the two must not drift.
            _sha_ok=false
            _head_sha="$(git rev-parse HEAD 2>/dev/null)"
            if [ -z "${_head_sha}" ]; then
                :   # unresolvable HEAD — probe 3's grep would degenerate to "^" and match anything
            elif git branch -r --contains "${_head_sha}" 2>/dev/null | grep -q .; then
                _sha_ok=true
            elif git fetch -q origin 2>/dev/null && \
                    git branch -r --contains "${_head_sha}" 2>/dev/null | grep -q .; then
                _sha_ok=true
            elif git ls-remote "${repo_url}" 2>/dev/null | grep -q "^${_head_sha}"; then
                _sha_ok=true
            fi
        fi
        if [ "${_sha_ok}" = skip ]; then
            :
        elif [ "${_sha_ok}" != true ]; then
            echo "  [note] parent pointer NOT recorded — ${_label} HEAD is on no remote"
            echo "         branch, so the parent would point at an unfetchable sha"
        else
            _sub_sha="$(git rev-parse --short HEAD)"
            _powner_var="GIT_OWNER_${TARGET_PROJECT}"
            _parent_url="git@github.com:${!_powner_var}/${TARGET_PROJECT}.git"
            print_banner_line "[${LOCAL_SERVER}] bump: ${TARGET_PROJECT} → ${SUB_PATH}@${_sub_sha}"
            docker exec ${BASE_CONTAINER} chown -R "$(id -u):$(id -g)" "${BASE_TARGET}/${TARGET_PROJECT}"
            cd "${_parent_path}" || { unset -n srv; exit 1; }
            git add -- "${SUB_PATH}" || { echo "[ERROR] bump: staging ${SUB_PATH} failed"; _prc=1; }
            if [ "${_prc}" -ne 0 ]; then
                :
            elif git diff --cached --quiet -- "${SUB_PATH}"; then
                echo "  [bump] pointer already current — nothing to record"
            else
                # Pathspec-scoped: whatever else the parent had staged stays staged.
                if git commit -m "chore: bump ${SUB_PATH} to ${_sub_sha}" -- "${SUB_PATH}"; then
                    _ahead="$(git log @{u}..HEAD --oneline 2>/dev/null | grep -cv '^$')"
                    [ "${_ahead:-0}" -gt 1 ] && \
                        echo "  [note] parent also has $((_ahead - 1)) other local commit(s) — pushing them too"
                    echo "  [push] ${TARGET_PROJECT}"
                    git push "${_parent_url}" || { echo "[ERROR] bump: parent push failed — pointer committed locally but NOT published"; _prc=1; }
                    [ "${_prc}" -eq 0 ] && _git_sync_tracking "${_parent_path}"
                else
                    echo "[ERROR] bump: parent commit failed — pointer not recorded"
                    _prc=1
                fi
            fi
        fi
    fi

    cd - > /dev/null
    unset -n srv
    echo ""
    if [ "${_prc:-0}" -eq 0 ]; then
        echo "[push_all] complete"
        exit 0
    else
        echo "[push_all] FAILED — see the [ERROR] line(s) above"
        exit 1
    fi
fi

# ═══════════════════════════════════════════════════════════════════
# ACTION: pull / clone — resolve targets, then per-server dispatch
# ═══════════════════════════════════════════════════════════════════
# clone drops the project's git_server_allow_push servers entirely (destructive
# on a dev machine is too dangerous). pull keeps them in the list — the action
# body downgrades them to a fetch-and-warn pattern so the user notices drift.
if [ "${TARGET_SERVER}" = "all" ]; then
    if [ "${ACTION}" = "clone" ]; then
        _targets=$(resolve_target_servers all no_push "${TARGET_PROJECT}") || exit 1
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

# Servers whose git work actually failed. The loop must not abort on the first
# failure (the remaining servers are independent), so failures accumulate here
# and the script exits nonzero at the end — callers script over this and cannot
# tell success from failure otherwise.
_failed_servers=""

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

    # The project's git_server_allow_push servers are where the user develops
    # it. We never modify their working copy automatically:
    #   clone -f → SKIP entirely (destructive, would erase uncommitted work)
    #   pull    → fetch only, then loudly WARN the user if local has diverged
    #             from origin so they can sync by hand. The actual pull is
    #             never run.
    if [ "${ACTION}" = "clone" ] && is_push_server "${name}" "${TARGET_PROJECT}"; then
        echo "[SKIP] ${name} — push server for '${TARGET_PROJECT}' (clone refuses; handle manually via ssh)"
        unset -n srv
        continue
    fi

    # A submodule with active_pull_if_allow_push_server lives only on the parent
    # project's push servers; everywhere else its gitlink stays an empty directory.
    if [ "${SUB_PUSH_SERVER_ONLY}" = "true" ] && ! is_push_server "${name}" "${TARGET_PROJECT}"; then
        echo "[SKIP] ${name} — '${TARGET_SUB}' is active_pull_if_allow_push_server (not a push server for '${TARGET_PROJECT}')"
        unset -n srv
        continue
    fi

    print_target_banner "${name}"

    # Ensure base container is running (auto-start if needed)
    ensure_base "${name}" || {
        _failed_servers="${_failed_servers} ${name}(container)"
        unset -n srv
        continue
    }

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
    # _rc carries the real verdict out: the chain is ';'-joined and several
    # branches end on a bookkeeping `cd -`, whose status would otherwise mask a
    # failed pull. Each git command that can genuinely fail sets _rc=1, and the
    # chain ends with `exit ${_rc}` so ssh propagates it to the caller.
    remote_cmds="_rc=0; "

    # Auto-accept github.com host key (avoids known_hosts write permission issues)
    remote_cmds="${remote_cmds}export GIT_SSH_COMMAND='ssh -p 22 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null'; "

    # Resolve target paths and labels — parent vs submodule scope
    if [ -n "${TARGET_SUB}" ]; then
        # Submodule scope
        host_path="${src_vol}/${TARGET_PROJECT}/${SUB_PATH}"
        docker_path="${BASE_TARGET}/${TARGET_PROJECT}/${SUB_PATH}"
        parent_host_path="${src_vol}/${TARGET_PROJECT}"
        repo_url="${SUB_REPO_URL}"
        _label="${TARGET_PROJECT}/${TARGET_SUB}"
        _clone_opts=""
        _active_sub_paths=""
    else
        # Parent scope — recurse into any nested submodules
        _sub_list_var="GIT_SUBMODULES_${TARGET_PROJECT}"
        # Recurse only into submodules that are active on THIS server — a gated
        # one (active_pull_if_allow_push_server) must not be cloned onto a
        # non-push box, so --recurse-submodules is replaced by an explicit
        # path-limited update.
        _active_sub_paths=""
        for _sn in ${!_sub_list_var:-}; do
            declare -n _sgate="SUBMODULE_${TARGET_PROJECT}_${_sn}"
            if [ "${_sgate[active_pull_if_allow_push_server]}" = "true" ] \
                && ! is_push_server "${name}" "${TARGET_PROJECT}"; then
                echo "  [submodule SKIP] ${_sn} — active_pull_if_allow_push_server"
            else
                _active_sub_paths="${_active_sub_paths}${_sgate[path]} "
            fi
            unset -n _sgate
        done
        _clone_opts=""

        _owner_var="GIT_OWNER_${TARGET_PROJECT}"
        repo_url="git@github.com:${!_owner_var}/${TARGET_PROJECT}.git"
        host_path="${src_vol}/${TARGET_PROJECT}"
        docker_path="${BASE_TARGET}/${TARGET_PROJECT}"
        parent_host_path=""
        _label="${TARGET_PROJECT}"
    fi

    # Repo-local submodule-safety config, applied on every clone AND every pull so
    # existing clones pick it up too (all three settings are idempotent). Parent
    # scope only — a submodule has no .gitmodules of its own. Mirrors
    # apply_repo_git_config in core/common/utils.sh; the two must not drift.
    # push.recurseSubmodules is the important one: without it a parent can push a
    # gitlink to a sha that was never pushed, and every other server then fails
    # `git submodule update` on the missing object.
    _cfg_cmd=""
    if [ -z "${TARGET_SUB}" ]; then
        _cfg_list_var="GIT_SUBMODULES_${TARGET_PROJECT}"
        if [ -n "${!_cfg_list_var:-}" ]; then
            # Idempotent + quiet-when-already-set (runs on every pull)
            _cfg_cmd="if [ \"\$(git -C ${host_path} config push.recurseSubmodules 2>/dev/null)\" != on-demand ]; then "
            _cfg_cmd="${_cfg_cmd}echo '  [git-config] ${_label} — submodule safety'; "
            _cfg_cmd="${_cfg_cmd}git -C ${host_path} config push.recurseSubmodules on-demand; "
            _cfg_cmd="${_cfg_cmd}git -C ${host_path} config submodule.recurse true; "
            _cfg_cmd="${_cfg_cmd}git -C ${host_path} config status.submoduleSummary true; "
            _cfg_cmd="${_cfg_cmd}fi; "
        fi
    fi

    # ─── BRANCH: clone (always destructive, push servers excluded) ───
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
            remote_cmds="${remote_cmds}echo '  [submodule update --init] ${_label}'; git submodule update --init -- ${SUB_PATH} || _rc=1; "
            remote_cmds="${remote_cmds}cd - > /dev/null; "
            remote_cmds="${remote_cmds}fi; "
        else
            # parent clone: rm (via docker, root files) + chown parent dir + clone
            remote_cmds="${remote_cmds}echo '  [rm] ${_label}'; docker exec ${BASE_CONTAINER} rm -rf ${docker_path}; "
            remote_cmds="${remote_cmds}docker exec ${BASE_CONTAINER} chown -R \$(id -u):\$(id -g) ${docker_path%/*}; "
            remote_cmds="${remote_cmds}mkdir -p ${src_vol}; "
            remote_cmds="${remote_cmds}echo '  [clone] ${_label}'; git clone ${_clone_opts} ${repo_url} ${host_path} || _rc=1; "
            remote_cmds="${remote_cmds}${_cfg_cmd}"
            if [ -n "${_active_sub_paths}" ]; then
                remote_cmds="${remote_cmds}echo '  [submodule] ${_label}'; ( cd ${host_path} && git submodule update --init --recursive -- ${_active_sub_paths} ) || _rc=1; "
            fi
        fi
    # ─── BRANCH: pull on push server (fetch-only + drift warning) ────
    elif is_push_server "${name}" "${TARGET_PROJECT}"; then
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
        remote_cmds="${remote_cmds}echo '  [WARNING] ${_label} on ${name} (push server) is OUT OF SYNC'; "
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
    # ─── BRANCH: pull on non-push server (clone-or-ff-only) ──────────
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
            remote_cmds="${remote_cmds}cd ${parent_host_path} && git submodule update --init -- ${SUB_PATH} || _rc=1; cd - > /dev/null; "
            remote_cmds="${remote_cmds}else "
            remote_cmds="${remote_cmds}docker exec ${BASE_CONTAINER} chown -R \$(id -u):\$(id -g) ${docker_path}; "
            remote_cmds="${remote_cmds}echo '  [fetch] ${_label}'; cd ${host_path} && git fetch origin || _rc=1; "
            remote_cmds="${remote_cmds}if git merge-base --is-ancestor HEAD FETCH_HEAD 2>/dev/null; then "
            remote_cmds="${remote_cmds}echo '  [pull] ${_label}'; git pull --ff-only || _rc=1; "
            remote_cmds="${remote_cmds}else echo '  [ERROR] ${_label}: not fast-forward, pull skipped (resolve manually)'; _rc=1; fi; "
            remote_cmds="${remote_cmds}cd - > /dev/null; "
            remote_cmds="${remote_cmds}fi; "
        else
            remote_cmds="${remote_cmds}if [ -d ${host_path} ]; then "
            remote_cmds="${remote_cmds}docker exec ${BASE_CONTAINER} chown -R \$(id -u):\$(id -g) ${docker_path}; "
            remote_cmds="${remote_cmds}echo '  [fetch] ${_label}'; cd ${host_path} && git fetch origin || _rc=1; "
            remote_cmds="${remote_cmds}if git merge-base --is-ancestor HEAD FETCH_HEAD; then "
            remote_cmds="${remote_cmds}echo '  [pull] ${_label}'; git pull --ff-only || _rc=1; "
            remote_cmds="${remote_cmds}${_cfg_cmd}"
            if [ -n "${_active_sub_paths}" ]; then
                remote_cmds="${remote_cmds}echo '  [submodule] ${_label}'; git submodule update --init --recursive -- ${_active_sub_paths} || _rc=1; "
            fi
            remote_cmds="${remote_cmds}else echo '  [ERROR] ${_label}: not fast-forward, pull skipped (resolve manually)'; _rc=1; fi; "
            remote_cmds="${remote_cmds}cd - > /dev/null; "
            remote_cmds="${remote_cmds}else "
            remote_cmds="${remote_cmds}docker exec ${BASE_CONTAINER} chown -R \$(id -u):\$(id -g) ${docker_path%/*}; "
            remote_cmds="${remote_cmds}mkdir -p ${src_vol}; "
            remote_cmds="${remote_cmds}echo '  [clone] ${_label}'; git clone ${_clone_opts} ${repo_url} ${host_path} || _rc=1; "
            remote_cmds="${remote_cmds}${_cfg_cmd}fi; "
        fi
    fi

    # Must be the last command in the chain — everything above is ';'-joined, so
    # without this the caller would read the status of whatever ran last.
    remote_cmds="${remote_cmds}exit \${_rc}; "

    # bash if current machine, otherwise SSH. We do NOT pass -t to ssh:
    # forcing a pseudo-tty makes ssh consume the outer while-read loop's
    # stdin (the heredoc), and only the first server gets processed. git
    # commands here are non-interactive so a tty is unnecessary.
    if is_local_server "${name}"; then
        bash -c "${remote_cmds}"
    else
        ssh ${agent_opt} ${port_opt} ${key_opt} ${user}@${srv[ip]} "${remote_cmds}" < /dev/null
    fi
    [ $? -ne 0 ] && _failed_servers="${_failed_servers} ${name}"
    unset -n srv
    echo ""
done 3<<< "${_targets}"

if [ -n "${_failed_servers}" ]; then
    echo "[ERROR] ${ACTION} failed on:${_failed_servers}"
    exit 1
fi
exit 0
