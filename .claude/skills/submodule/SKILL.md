---
description: "Submodule — backup/restore + convert between tracked files and git submodule"
disable-model-invocation: false
user-invocable: true
argument-hint: [action] [project] [submodule]
allowed-tools: Bash(*)
---

Run `.claude/skills/submodule/scripts/submodule.sh`.

## Important: always confirm the options with the user before running

**Never decide the options on your own and run immediately.**
Refer to the option information below, ask the user for the option values needed, then run.

### Usage
```
 Usage:
   ./submodule.sh -a init   -p <project> -s <submodule>  — false→true: backup files + convert to submodule
   ./submodule.sh -a deinit -p <project> -s <submodule>  — true→false: remove submodule + restore from backup
   ./submodule.sh -h                                     — show help
```

### Options
```
 Options:
   -a <action>     action: init | deinit
   -p <project>    parent project (must contain the named submodule)
   -s <submodule>  submodule name (must be defined under the project in configuration.yaml)
   -h              show help
```

## Procedure

1. Check the current server info in `md_files/users/users.yaml`.
2. Ask the user for the option values needed.
3. Run `.claude/skills/submodule/scripts/submodule.sh` with the options the user confirmed.
