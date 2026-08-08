#!/bin/bash
# ============================================
#  Submodule — backup/restore + convert between tracked files and git submodule
#
#  Usage:
#    ./submodule.sh -a init   -p <project> -s <submodule>  — false→true: backup files + convert to submodule
#    ./submodule.sh -a deinit -p <project> -s <submodule>  — true→false: remove submodule + restore from backup
#    ./submodule.sh -h                                     — show help
#
#  Options:
#    -a <action>     action: init | deinit
#    -p <project>    parent project (must contain the named submodule)
#    -s <submodule>  submodule name (must be defined under the project in configuration.yaml)
#    -h              show help
#
#  Why -p is required:
#    Different parent projects may declare submodules with the same name, so the
#    lookup is keyed by (parent, sub) → SUBMODULE_<parent>_<sub>.
#    Always runs on the current server only — no -t option.
#
#  init (false → true):
#    1. Copy existing files to reference_codes/{submodule}/
#    2. Create reference_codes/{submodule}.md with restore metadata
#    3. git rm -r --cached {path} + rm -rf {path}
#    4. git submodule add {url} {path}
#    5. git add reference_codes/
#
#  deinit (true → false):
#    1. git submodule deinit {path}
#    2. git rm {path}
#    3. rm -rf .git/modules/{submodule}
#    4. Restore files from reference_codes/{submodule}/ to {path}
#    5. Remove reference_codes/{submodule}/ and .md
#    6. git add {path}
#
#  After either action, run {project}_push_all to commit changes.
#  Remote servers: core/git/git.sh -a clone -p {project} -t all -f
#
#  Requires:
#    - "base_{PROJECT_USER}" docker container for chown
#    - Submodule must be defined in configuration.yaml
# ============================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
eval "$(python3 "${SCRIPT_DIR}/exec.py" "$(cd "${SCRIPT_DIR}/../../../.." && pwd)/md_files/users/users.yaml" "sonny")"
source "${SCRIPT_DIR}/utils.sh"

_show_help() { sed -n '2,/^# ====.*$/p' "$0" | sed 's/^# \?//'; exit 0; }

ACTION=""
TARGET_PARENT=""
TARGET_SUB=""
SHOW_HELP=false

while getopts "a:p:s:h" opt; do
    case $opt in
        a) ACTION="$OPTARG" ;;
        p) TARGET_PARENT="$OPTARG" ;;
        s) TARGET_SUB="$OPTARG" ;;
        h) SHOW_HELP=true ;;
        *) echo "Usage: $0 -a <init|deinit> -p <project> -s <submodule> [-h]"; exit 1 ;;
    esac
done

[ "${SHOW_HELP}" = true ] && _show_help

# Validate
if [ -z "${ACTION}" ] || [ -z "${TARGET_PARENT}" ] || [ -z "${TARGET_SUB}" ]; then
    echo "[ERROR] -a, -p and -s options are required"
    echo "Usage: $0 -a <init|deinit> -p <project> -s <submodule>"
    exit 1
fi

if [ "${ACTION}" != "init" ] && [ "${ACTION}" != "deinit" ]; then
    echo "[ERROR] -a must be 'init' or 'deinit'"
    exit 1
fi

# Project must be a known git project (default ∪ user, both sides safely
# guarded inside is_known_git_project)
if ! is_known_git_project "${TARGET_PARENT}"; then
    echo "[ERROR] unknown parent project: '${TARGET_PARENT}'"
    exit 1
fi

# Submodule lookup keyed by (parent, sub) → SUBMODULE_<parent>_<sub>
declare -n _sub="SUBMODULE_${TARGET_PARENT}_${TARGET_SUB}" 2>/dev/null
if [ ${#_sub[@]} -eq 0 ]; then
    echo "[ERROR] submodule '${TARGET_SUB}' not declared under project '${TARGET_PARENT}'"
    echo "  Available (parent_sub): ${SUBMODULE_LIST[*]}"
    exit 1
fi

PARENT="${_sub[parent]}"
SUB_PATH="${_sub[path]}"
SUB_GIT_OWNER="${_sub[git_owner]}"
unset -n _sub

PROJECT_PATH="${DEFAULT_SOURCE_MNT_PATH}/${PARENT}"
FULL_SUB_PATH="${PROJECT_PATH}/${SUB_PATH}"
REF_DIR="${PROJECT_PATH}/reference_codes/${TARGET_SUB}"
REF_MD="${PROJECT_PATH}/reference_codes/${TARGET_SUB}.md"
SUB_URL="git@github.com:${SUB_GIT_OWNER}/${TARGET_SUB}.git"

# Get docker paths for chown
declare -n _base_img="DOCKER_base"
DOCKER_VOL="${_base_img[target_mnt_path]}"
unset -n _base_img
DOCKER_PROJECT="${DOCKER_VOL}/${PARENT}"

if [ ! -d "${PROJECT_PATH}" ]; then
    echo "[ERROR] project directory not found: ${PROJECT_PATH}"
    exit 1
fi

# Ensure base container for chown
detect_local_server || { echo "[ERROR] Could not detect current server"; exit 1; }
ensure_base "${DETECTED_SERVER}" || exit 1

# chown project so host user can write
echo "[chown] ${PARENT}"
docker exec ${BASE_CONTAINER} chown -R "$(id -u):$(id -g)" "${DOCKER_PROJECT}"

# ═══════════════════════════════════════════════════════════════════
# ACTION: init — convert regular files to a git submodule (with backup)
# ═══════════════════════════════════════════════════════════════════
if [ "${ACTION}" = "init" ]; then
    print_banner_line "[submodule init] ${TARGET_SUB} (${PARENT})"

    # Check: files must exist at submodule path
    if [ ! -d "${FULL_SUB_PATH}" ]; then
        echo "[ERROR] directory not found: ${FULL_SUB_PATH}"
        echo "  Nothing to backup. If already a submodule, use 'deinit' instead."
        exit 1
    fi

    # Check: must NOT already be a submodule
    if [ -f "${PROJECT_PATH}/.gitmodules" ] && grep -q "path = ${SUB_PATH}" "${PROJECT_PATH}/.gitmodules" 2>/dev/null; then
        echo "[ERROR] '${TARGET_SUB}' is already registered as a submodule in .gitmodules"
        exit 1
    fi

    # Step 1: Backup to reference_codes. The backup MUST be verified before the
    # destructive steps below (git rm --cached + rm -rf) — a partial copy that
    # slipped through here used to mean silent data loss at step 4.
    echo "  [backup] ${SUB_PATH} → reference_codes/${TARGET_SUB}/"
    # A REF_DIR here can only be the leftover of a previously FAILED init (a
    # completed one is blocked above by the .gitmodules check) — refresh it, or
    # stale files merge into the new backup and resurface at restore.
    [ -d "${REF_DIR}" ] && { echo "  [backup] stale ${REF_DIR} from a failed prior run — refreshing"; rm -rf "${REF_DIR}"; }
    mkdir -p "${REF_DIR}" || { echo "[ERROR] backup dir creation failed: ${REF_DIR}"; exit 1; }
    # Use cp -a to preserve permissions and structure
    cp -a "${FULL_SUB_PATH}/." "${REF_DIR}/" || { echo "[ERROR] backup copy failed — nothing was removed, aborting"; exit 1; }
    _file_count=$(find "${REF_DIR}" -type f | wc -l)
    _src_count=$(find "${FULL_SUB_PATH}" -type f | wc -l)
    if [ "${_file_count}" -ne "${_src_count}" ]; then
        echo "[ERROR] backup incomplete (${_file_count}/${_src_count} files) — nothing was removed, aborting"
        exit 1
    fi
    echo "  [backup] ${_file_count} files copied"

    # Step 2: Create restore metadata .md
    echo "  [metadata] reference_codes/${TARGET_SUB}.md"
    cat > "${REF_MD}" << MDEOF
# Submodule Backup: ${TARGET_SUB}

| Field          | Value                                           |
|----------------|------------------------------------------------|
| submodule      | ${TARGET_SUB}                                   |
| parent_project | ${PARENT}                                       |
| original_path  | ${SUB_PATH}                                     |
| git_url        | ${SUB_URL}                                      |
| backup_date    | $(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S KST') |
| file_count     | ${_file_count}                                  |

## Restore

To restore these files (submodule → regular files):

\`\`\`bash
# Option 1: via alias
${PARENT}_${TARGET_SUB}_sub_deinit

# Option 2: via exec script
core/submodule/submodule.sh -a deinit -p ${PARENT} -s ${TARGET_SUB}
\`\`\`
MDEOF

    # Step 3: git rm --cached (remove from tracking, files still on disk)
    echo "  [git rm --cached] ${SUB_PATH}"
    cd "${PROJECT_PATH}" || exit 1
    git rm -r --cached "${SUB_PATH}" 2>/dev/null

    # Step 4: Remove directory (files are backed up)
    echo "  [rm] ${SUB_PATH}"
    rm -rf "${FULL_SUB_PATH}"

    # Step 5: git submodule add
    echo "  [submodule add] ${SUB_URL} → ${SUB_PATH}"
    export GIT_SSH_COMMAND='ssh -p 22 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null'
    git submodule add "${SUB_URL}" "${SUB_PATH}"
    if [ $? -ne 0 ]; then
        echo "[ERROR] git submodule add failed"
        echo "  Restoring from backup..."
        cp -a "${REF_DIR}/." "${FULL_SUB_PATH}/"
        cd "${PROJECT_PATH}" && git add "${SUB_PATH}"
        echo "  Files restored. Please check and retry manually."
        cd - > /dev/null
        exit 1
    fi

    # Step 6: Stage reference_codes
    echo "  [git add] reference_codes/"
    git add "reference_codes/" || { echo "[ERROR] staging reference_codes/ failed — stage it manually before push"; exit 1; }

    cd - > /dev/null

    echo ""
    echo "[init] complete"
    echo "  Next steps:"
    echo "    ${PARENT}_push_all \"add ${TARGET_SUB} as submodule\""
    echo "    # Remote servers:"
    echo "    core/git/git.sh -a clone -p ${PARENT} -t all -f"
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════
# ACTION: deinit — convert submodule back to regular files (from backup)
# ═══════════════════════════════════════════════════════════════════
if [ "${ACTION}" = "deinit" ]; then
    print_banner_line "[submodule deinit] ${TARGET_SUB} (${PARENT})"

    # Check: must be a submodule
    if [ ! -f "${PROJECT_PATH}/.gitmodules" ] || ! grep -q "path = ${SUB_PATH}" "${PROJECT_PATH}/.gitmodules" 2>/dev/null; then
        echo "[ERROR] '${TARGET_SUB}' is not registered as a submodule in .gitmodules"
        exit 1
    fi

    # Check: backup must exist
    if [ ! -d "${REF_DIR}" ]; then
        echo "[ERROR] backup not found: ${REF_DIR}"
        echo "  Cannot restore without backup. To just remove the submodule without restore:"
        echo "    cd ${PROJECT_PATH}"
        echo "    git submodule deinit ${SUB_PATH}"
        echo "    git rm ${SUB_PATH}"
        echo "    rm -rf .git/modules/${TARGET_SUB}"
        exit 1
    fi

    # Check: nothing in the submodule may be lost. deinit runs `git rm -f` and
    # `rm -rf .git/modules/<sub>`, which destroys unpushed commits, uncommitted
    # edits and untracked files with no warning — and the submodule's own repo is
    # the ONLY copy of them. Every state below is a hard stop, not a prompt.
    _sub_abs="${PROJECT_PATH}/${SUB_PATH}"
    _blockers=""
    if [ -e "${_sub_abs}/.git" ]; then
        git -C "${_sub_abs}" diff --quiet 2>/dev/null \
            || _blockers="${_blockers}\n  - uncommitted changes to tracked files"
        git -C "${_sub_abs}" diff --cached --quiet 2>/dev/null \
            || _blockers="${_blockers}\n  - staged but uncommitted changes"
        [ -n "$(git -C "${_sub_abs}" ls-files --others --exclude-standard 2>/dev/null)" ] \
            && _blockers="${_blockers}\n  - untracked files (never pushed anywhere)"
        _sub_branch="$(git -C "${_sub_abs}" rev-parse --abbrev-ref HEAD 2>/dev/null)"
        if git -C "${_sub_abs}" rev-parse --verify -q "origin/${_sub_branch}" >/dev/null 2>&1; then
            _ahead="$(git -C "${_sub_abs}" rev-list --count "origin/${_sub_branch}..HEAD" 2>/dev/null)"
            [ "${_ahead:-0}" -gt 0 ] \
                && _blockers="${_blockers}\n  - ${_ahead} commit(s) ahead of origin/${_sub_branch} (unpushed)"
        else
            _blockers="${_blockers}\n  - no origin/${_sub_branch} — this branch was never pushed"
        fi
        # The parent's gitlink is what other servers fetch. If it lags the
        # submodule HEAD, the work is pushed but unreachable from the parent.
        _recorded="$(git -C "${PROJECT_PATH}" rev-parse "HEAD:${SUB_PATH}" 2>/dev/null)"
        _actual="$(git -C "${_sub_abs}" rev-parse HEAD 2>/dev/null)"
        [ -n "${_recorded}" ] && [ "${_recorded}" != "${_actual}" ] \
            && _blockers="${_blockers}\n  - parent gitlink ${_recorded:0:8} != submodule HEAD ${_actual:0:8} (pointer not committed in the parent)"
    fi
    if [ -n "${_blockers}" ]; then
        echo "[ERROR] '${TARGET_SUB}' has work that deinit would destroy:"
        printf '%b\n' "${_blockers}"
        echo ""
        echo "  Resolve inside the submodule first, then re-run deinit:"
        echo "    cd ${_sub_abs}"
        echo "    git status"
        echo "    git add -A && git commit -m \"...\" && git push"
        echo "  Then record the pointer in the parent:"
        echo "    cd ${PROJECT_PATH} && git add ${SUB_PATH} && ${PARENT}_push_all \"bump ${TARGET_SUB}\""
        exit 1
    fi

    cd "${PROJECT_PATH}" || exit 1

    # Step 1: git submodule deinit
    echo "  [submodule deinit] ${SUB_PATH}"
    git submodule deinit -f "${SUB_PATH}"

    # Step 2: git rm
    echo "  [git rm] ${SUB_PATH}"
    git rm -f "${SUB_PATH}"

    # Step 3: Clean .git/modules
    echo "  [cleanup] .git/modules/${TARGET_SUB}"
    rm -rf ".git/modules/${TARGET_SUB}"

    # Step 4: Restore from backup. Verified BEFORE step 5 deletes the backup —
    # an unchecked cp here followed by rm -rf of the backup was a data-loss path.
    echo "  [restore] reference_codes/${TARGET_SUB}/ → ${SUB_PATH}"
    mkdir -p "${FULL_SUB_PATH}" || { echo "[ERROR] restore dir creation failed"; exit 1; }
    cp -a "${REF_DIR}/." "${FULL_SUB_PATH}/" || { echo "[ERROR] restore copy failed — backup kept at ${REF_DIR}"; exit 1; }
    _file_count=$(find "${FULL_SUB_PATH}" -type f | wc -l)
    _ref_count=$(find "${REF_DIR}" -type f | wc -l)
    if [ "${_file_count}" -lt "${_ref_count}" ]; then
        echo "[ERROR] restore incomplete (${_file_count}/${_ref_count} files) — backup kept at ${REF_DIR}"
        exit 1
    fi
    echo "  [restore] ${_file_count} files restored"

    # Step 5: Remove backup
    echo "  [cleanup] reference_codes/${TARGET_SUB}/ and ${TARGET_SUB}.md"
    rm -rf "${REF_DIR}"
    rm -f "${REF_MD}"
    # Remove reference_codes/ dir if empty
    rmdir "${PROJECT_PATH}/reference_codes" 2>/dev/null

    # Step 6: Stage restored files
    echo "  [git add] ${SUB_PATH}"
    git add "${SUB_PATH}" || { echo "[ERROR] staging restored ${SUB_PATH} failed — stage it manually before push"; exit 1; }
    # Stage reference_codes removal
    git add -A "reference_codes/" 2>/dev/null

    cd - > /dev/null

    echo ""
    echo "[deinit] complete"
    echo "  Next steps:"
    echo "    ${PARENT}_push_all \"remove ${TARGET_SUB} submodule, restore as regular files\""
    echo "    # Remote servers:"
    echo "    core/git/git.sh -a clone -p ${PARENT} -t all -f"
    exit 0
fi
