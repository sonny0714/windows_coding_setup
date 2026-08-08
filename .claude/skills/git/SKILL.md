---
description: "Git operations across servers — pull / clone -f / push_all on a parent project or a single submodule (-s), with docker chown"
disable-model-invocation: false
user-invocable: true
argument-hint: [action] [project] [submodule?] [server] [message?]
allowed-tools: Bash(*)
---

Run `.claude/skills/git/scripts/git.sh`.

## Important: always confirm the options with the user before running

**Never decide the options on your own and run immediately.**
Refer to the option information below, ask the user for the option values needed, then run.

### Usage
```
 Usage (parent project):
   ./git.sh -a pull  -p <project> -t all
   ./git.sh -a pull  -p <project> -t <server>
   ./git.sh -a clone -p <project> -t all     -f
   ./git.sh -a clone -p <project> -t <server> -f
   ./git.sh -a push_all -p <project> -m "msg"
   ./git.sh -a push_all -p <project> -m "msg" -b <branch>

 Usage (single submodule of a project — same actions, just add -s):
   ./git.sh -a pull  -p <project> -s <submodule> -t all
   ./git.sh -a clone -p <project> -s <submodule> -t <server> -f
   ./git.sh -a push_all -p <project> -s <submodule> -m "msg" [-b <branch>]
                            ^ pushes the submodule AND records the new pointer in
                              the parent (add gitlink + commit + push). Add -N to
                              skip that and leave the parent on the old sha —
                              which means the submodule change never enters the
                              parent's history.
```

### Options
```
 Options:
   -a <action>     pull | clone | push_all (default: pull)
   -p <project>    target project — required (default + user list)
   -s <submodule>  scope to a single submodule of -p (must be defined as
                   SUBMODULE_<project>_<submodule> in configuration.sh).
                   Without -s the action targets the parent project itself.
   -t <server>     target server — required for pull/clone ("all" = common rule)
   -m <message>    commit message for push_all — required
   -b <branch>     push_all only: push HEAD to this remote branch (git push
                   <url> HEAD:<branch>). Omit → git push <url> (current branch).
   -N              push_all -s only: do NOT bump the parent's gitlink afterwards.
                   The bump is the default because leaving the parent on the old
                   sha is the mistake, not the intent; it is safe by default
                   because it runs only after the push succeeded and re-checks
                   that the sha is on a remote branch.
   -f              clone only: explicit acknowledgement that clone is destructive
   -h              show help
```

## Procedure

1. Check the current server info in `md_files/users/users.yaml`.
2. Ask the user for the option values needed.
3. Run `.claude/skills/git/scripts/git.sh` with the options the user confirmed.
