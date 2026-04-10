# CLAUDE.md

Global rules for Claude Code. Project-independent guidelines only.
- User-specific rules: `md_files/worklog/{username}/claude_user.md`
- Project-specific guide: `md_files/project.md`
- **When adding rules**: project-specific rules/conventions go in `project.md`, general rules in this file
- **This file must be written in English only** — Korean content belongs in `project.md` or user-specific files

# Claude Behavior Summary

- Respond in Korean
- Code must be intuitive, concise, and clear
- Comments in English, one line max
- Avoid unnecessary abstraction
- Prefer functional, Pythonic style
- Don't over-assume; explain code step-by-step by function if long
- When instructed "do without asking", execute automatically without permission prompts
- When user input contains `http://` before filenames (e.g. `http://xxx.py`, `http://learning.md`), strip the `http://` and treat as plain filename

## Coding Guidelines

General principles for writing or modifying code. Project-specific conventions belong in `project.md`.

| Rule | Why |
|------|-----|
| **Single source of truth** | Any constant used by multiple call sites is defined once at module top, not duplicated inline. |
| **No magic numbers** | A literal appearing in 2+ places must be hoisted to a named constant. |
| **Extract helpers for repeated boilerplate** | If 3+ call sites share the same multi-line pattern, wrap it in a helper. Helpers make the contract explicit and prevent per-callsite drift. |
| **Force explicit ordering for grouped/categorical data** | When grouping by a known fixed set of categories, always pass the complete expected list to the library (`order=`, `reindex(...)`, etc.) so missing buckets do not silently shift positions. |
| **Verify label ↔ data alignment** | Many plotting libraries place categorical data at integer positions `0..N-1`, not at data values. When manually setting ticks/labels on such axes, confirm positions actually map to the intended values. |
| **Read before edit** | Before modifying a function, read its full body and grep for all call sites. Never patch a literal you only saw in one place — the same pattern likely exists elsewhere. |
| **Verify after refactor** | After extracting helpers, renaming, or changing units/conversions, regenerate any downstream artifacts and compare to the previous output before declaring done. |

## Bash gotchas

Subtle traps that have bitten this project before — silent failures, not bash errors. If you see a "stops after the first iteration" or "only the first server got processed" symptom, suspect these first.

| Trap | Symptom | Fix |
|------|---------|-----|
| **`while read` loop + `ssh` inside** | Loop exits after first iteration. ssh inherits the loop's stdin (fd 0), reads the rest of the heredoc, and the next `read` hits EOF. | Isolate the loop's stdin on fd 3: `while IFS= read -r x <&3; do ... done 3<<< "$list"`. Also call ssh **without `-t`** for non-interactive commands (a forced pty re-grabs fd 0 even with `< /dev/null`). |
| **`ssh -t` for batch commands** | Same stdin-consumption symptom; pty also breaks `< /dev/null` redirection. | Drop `-t`. Use `ssh -n` or fd 3 isolation if you need belt-and-braces. Only keep `-t` for genuinely interactive remote sessions. |
| **`hostname -I` prefix matching for "is this server me?"** | Wrong server detected when one server's IP is a string prefix of another (e.g. `192.168.1.1` matches `192.168.1.10`), or when a wildcard config matches a docker bridge interface. | Match every IP from `hostname -I` *exactly* (or via the project's `ip_matches_pattern` octet-aware wildcard). Most-specific pattern wins on ties. |
| **Unset `${VAR[@]}` under `set -u`** | Standalone copies of utils.sh die with `unbound variable` because `DEFAULT_*_LIST` isn't defined in the standalone exec.py environment. | Guard with `[ -n "${VAR+x}" ]` before iterating, or pre-merge the data so the standalone never sees a missing variable. |

## Markdown Writing Style

When creating or editing `.md` files, follow these guidelines:

| Category       | Guideline                                                              |
|----------------|------------------------------------------------------------------------|
| **Structure**  | Use clear heading hierarchy (H1 → H2 → H3), group content by category |
| **Readability**| Prefer tables for comparisons/specs, use lists for sequential items    |
| **Conciseness**| One idea per bullet, no filler — keep sentences short and direct       |
| **Formatting** | Bold (`**key**`) for key terms, backticks for code/paths/commands      |
| **Lists**      | Use hyphens (`-`) consistently, tab-indent for sub-levels              |
| **Code**       | Always specify language in fenced blocks (` ```python `, ` ```bash `) |
| **Links**      | Cross-reference related docs with relative paths                       |
| **Whitespace** | One blank line between sections, no trailing whitespace                |

## Completion Checklist

After completing any task (staging, code modification, question response), verify:
1. All items in the staging/request are addressed — do not skip sub-items
2. Modified code files are consistent with each other
3. If a function signature changed, all call sites are updated
4. Tests still pass (run if available)
5. Alias/setup files are synced if worklog or command files were modified

## Alias Dependency

Git commands (`/git:*`) and Docker/Exec commands (`/exec:*`) reference scripts from the alias project.
- alias path: `users.yaml` → `users.{username}.{server}.alias_dir`
  - Server detection: `hostname -I` for IP, `$SSH_CONNECTION` for port → match against ip/port in users
- **These commands are unavailable without the alias project.**
- New environment setup: `git clone` then `./init_configuration.sh` → interactive server info input → `configuration.sh` auto-generated
- `configuration.sh` is gitignored (contains personal server info)

### This file is auto-generated — sync rule

**`md_files/claude.md` is generated from `alias/project_setup/worklog_setup.sh` (`GLOBAL_CLAUDE_MD` heredoc).**
The same applies to all other files installed by `worklog_setup.sh` — see the `Installs` section at the top of that script for the full list (e.g. `md_files/worklog/{user}/run.md` ← `_gen_user_run`, `backlog.md` ← `BACKLOG_MD`, command `.md` files ← `_gen_cmd_*`).

When editing any of these files, you **must** also edit the corresponding source in the alias script — otherwise the next `worklog_setup.sh` run will overwrite your change, and other projects/users will not receive it.

Mandatory procedure when modifying any auto-generated file (claude.md, run.md, backlog.md, worklog command `.md` files, etc.):

1. Edit the project file (e.g. `md_files/claude.md`) — for immediate effect in the current project.
2. Edit the matching source in `alias/project_setup/worklog_setup.sh` (the relevant heredoc or `_gen_*` function) — so other projects/users get the change too.
3. **Verify parity** — extract the heredoc/function output and `diff` against the project file. They must be byte-identical. Example for `GLOBAL_CLAUDE_MD` (use `--noprofile --norc` so shell rcfile output does not pollute stdout):
   ```bash
   bash --noprofile --norc -c '
     source <(sed -n "/^read -r -d .. GLOBAL_CLAUDE_MD/,/^FILEEOF$/p" alias/project_setup/worklog_setup.sh)
     printf "%s\n" "$GLOBAL_CLAUDE_MD"
   ' > /tmp/alias_claude.md
   diff -q /tmp/alias_claude.md md_files/claude.md
   ```
4. `bash -n alias/project_setup/worklog_setup.sh` to confirm the script still parses.

Do this **without being asked**. Treat any edit to an auto-generated file as a two-file edit + verification by default.

## Docker Environment (Base)

Commands run inside Docker containers. Do NOT run commands directly on host.
Container names include PROJECT_USER suffix: \`base_{PROJECT_USER}\` (e.g. \`base_sonny\`).

- **\`base_{PROJECT_USER}\`**: file operations, general terminal commands, and project-independent code execution
- Project-specific containers (e.g., GPU/Python execution): see \`md_files/project.md\`

### When to Use \`base_{PROJECT_USER}\`

- File operations requiring root (rm, mv, cp, chown, mkdir, etc.)
- General terminal commands (ls, find, grep, etc.)
- Project-independent test scripts (Python, C++ snippets not tied to project files)

### Container Activation

If \`base_{PROJECT_USER}\` is not running, activate it using the alias project's exec scripts:

\`\`\`bash
# Check container status
docker ps -a --format '{{.Names}} {{.Status}}' | grep base_{PROJECT_USER}

# If stopped (Exited): restart
docker start base_{PROJECT_USER}

# If not found: create via exec/docker.sh
# {alias_dir} = users.yaml → users.{username}.{server}.alias_dir
{alias_dir}/exec/docker.sh -i base -t <server>
\`\`\`

### Commands

**IMPORTANT**: Do NOT chain commands with \`&&\`. Always use separate \`docker exec\` calls per command.

\`\`\`bash
# File operations (rm, mv, cp, mkdir, chown, etc.)
docker exec -w <workdir> base_{PROJECT_USER} <command>

# General Python execution (always prevent __pycache__)
docker exec -e PYTHONDONTWRITEBYTECODE=1 -w <workdir> base_{PROJECT_USER} python3 <script>

# General C++ compilation/execution
docker exec -w <workdir> base_{PROJECT_USER} g++ -o <output> <source> && docker exec -w <workdir> base_{PROJECT_USER} ./<output>
\`\`\`

### Remote Server Execution (SSH + Docker)

Long-running remote tasks (benchmarks, training, dataset fetch) must be **decoupled from the SSH session**, otherwise an SSH disconnect kills the process. The default approach is `docker exec -d` + `tee` to a host-mounted log file.

#### Default: `docker exec -d` + `tee` to mounted log

\`\`\`bash
# 1. Pick a log path under the host-mounted source dir (NOT inside container fs)
#    {target_mnt_path}/tee_log/{project_name}/{YYYYMMDD-HHMMSS}.log
LOG={target_mnt_path}/tee_log/{project_name}/$(date +%Y%m%d-%H%M%S).log

# 2. Make sure the log dir exists, then launch detached
ssh user@server "docker exec {container} mkdir -p \$(dirname \$LOG)"
ssh user@server "docker exec -d {container} bash -c 'python3 -u /path/script.py > \$LOG 2>&1'"
\`\`\`

- **Log path under `target_mnt_path`** → file lives on the host mount, container storage does not grow, host can `tail` without entering the container.
- **`-u`** disables Python output buffering (real-time log).
- **`-d`** detaches; the process is owned by the docker daemon, completely independent of SSH.
- **Filename = launch timestamp** (`YYYYMMDD-HHMMSS`) so re-runs do not collide and ordering is obvious.

#### Status / progress check

\`\`\`bash
# Is it still running?
ssh user@server "docker exec {container} pgrep -f <script.py> >/dev/null && echo running || echo done"

# Last 20 log lines
ssh user@server "docker exec {container} tail -20 {log_path}"

# Or read the log directly from host (it's on the mount)
tail -20 {source_mnt_path}/tee_log/{project_name}/{YYYYMMDD-HHMMSS}.log
\`\`\`

#### Track every long-run in `md_files/worklog/{user}/run.md`

When starting a long-run, append an entry to the user's `run.md`. This is the single source of truth for "what is currently running where". Required fields per entry: `server`, `container`, `started`, `expected_duration`, `next_check_after`, `command`, `log_path`, `result_path`, `check_cmd`, `tail_cmd`. Section header format: `## [running|done|failed] <run_id>`. See `md_files/worklog/{user}/run.md` for the full template.

- Claude is **not a daemon**: it does not poll on its own. Status is checked only when the user invokes claude (e.g. during `/worklog:{user}:run-staging` or "진행 확인해줘"). `next_check_after` is a hint for the user to know when to ask again.
- For result files saved to disk, no polling is needed — check completion via `pgrep` / file mtime when the user asks.

#### Exceptions — when to use tmux / SSH keepalive instead

- **tmux**: only when an interactive TUI is required (pdb, ipython, manual progress watching). Otherwise the `tee` log file replaces the need for tmux entirely.
- **SSH keepalive** (`-o ServerAliveInterval=30 -o ServerAliveCountMax=120`): only for short-to-medium *interactive* foreground sessions where decoupling is overkill. Not a substitute for `docker exec -d` on long runs — keepalive keeps the SSH pipe alive but the foreground process still dies if anything kills the SSH client.

\`\`\`bash
# Interactive foreground (short, debugging) — keepalive only
ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=120 user@server "docker exec ... command"

# SSH agent forwarding 필요 시 -A 추가 (git pull 등)
\`\`\`

### Python \`__pycache__\` Prevention

Always add \`-e PYTHONDONTWRITEBYTECODE=1\` when running Python via \`docker exec\`. This applies to all containers (\`base_{PROJECT_USER}\`, project-specific containers, etc.).

### File Ownership

Docker creates files as root. After creating/moving files via Docker, restore ownership to the host user:

\`\`\`bash
docker exec -w <workdir> base_{PROJECT_USER} chown -R \$(stat -c '%u:%g' .) <target>
\`\`\`

## Usertag Convention

When run-staging creates, deletes, or modifies functions/classes, add a usertag comment at the definition.
**Only applied when 2+ worklog users are registered** (skip if only 1 user).

```python
# worklog:usertag: user1
def new_function():
    ...

# worklog:usertag: user1 user2
class ModifiedClass:
    ...
```

- Tag goes on the line immediately above the `def`/`class` definition
- If an existing usertag exists, append the new user_name: `# worklog:usertag: user1 user2`
- Only applied during run-staging execution (not manual edits)
- Purpose: track who requested each code change for easy rollback/review
- Check user count: `md_files/worklog/config.yaml` → `registered_users` list

## Refactoring Convention

Refactoring is managed per topic under `refactoring/`.

### Directory Structure
```
refactoring/
├── {topic}/                    # per-topic directory
│   ├── refactoring.md          # plan, progress, start/end dates
│   └── (original backup files) # diff reference (not executable, do not modify)
└── backup/                     # completed topic's refactoring_{topic}.md archive
```

### Rules
1. Organize refactoring files in per-topic directories under `refactoring/`
2. Record start date and topic in `refactoring/{topic}/refactoring.md`
3. Write detailed plan in the topic's `refactoring.md`
4. Execute refactoring according to `refactoring.md` plan
5. After initial completion, compare with original files in `refactoring/{topic}/` to verify algorithm consistency
6. Record end date in `refactoring.md` when refactoring is complete
7. After topic cleanup, move only `refactoring_{topic}.md` to `refactoring/backup/`

## Multi-User Worklog

- Each user has their own worklog directory: `md_files/worklog/{username}/`
- User-specific files: `claude_user.md`, `staging.md`, `backlog.md`, `daily/`, `weekly/`
- Global files: `md_files/claude.md` (this file), `md_files/project.md`, `md_files/worklog/config.yaml`, `md_files/worklog/users.yaml`
- Slash commands are namespaced: `/worklog:{username}:run-staging`, `/worklog:{username}:staging`, etc.
- User setup: `/worklog:user-setup add {username}` — creates user directory and commands
- Available commands: run `/worklog:help` or see `.claude/commands/worklog/help.md`
