---
description: "Sync experiment artifacts between servers — collect runs (all or selected run_ids, optional destination) / distribute models via rsync"
disable-model-invocation: false
user-invocable: true
argument-hint: [mode] [project] [server] [run_ids?] [dest?]
allowed-tools: Bash(*)
---

Run `.claude/skills/artifact_sync/scripts/artifact_sync.sh`.

## Important: always confirm the options with the user before running

**Never decide the options on your own and run immediately.**
Refer to the option information below, ask the user for the option values needed, then run.

### Usage
```
 Usage:
   ./artifact_sync.sh -a collect -p <project> -t all       — collect runs from all active servers
   ./artifact_sync.sh -a c -p <project> -t all             — short for collect
   ./artifact_sync.sh -a distribute -p <project> -t all    — distribute models to all active servers
   ./artifact_sync.sh -a d -p <project> -t all             — short for distribute
   ./artifact_sync.sh -a c -p <project> -t <server>        — collect from specific server
   ./artifact_sync.sh -a d -p <project> -t <server> -f     — distribute to server, clear models first
   ./artifact_sync.sh -a c -p <project> -t all -r <id,id>  — collect only these run_ids
   ./artifact_sync.sh -a c -p <project> -t all -R - -x weights   — run_ids from stdin, logs only
   ./artifact_sync.sh -a c -p <project> -t all -r <id> -D outputs/models/<topic>/<sub>
                                                           — collect straight into the promoted path
```

### Options
```
 Options:
   -a <mode>    collect (c) or distribute (d) — required
   -p <project> target project — required
   -t <server>  target server — required ("all" = all server_active_status=true servers)
   -r <ids>     collect only these run_ids (comma/space separated), repeatable
   -R <file>    collect only run_ids read from a file ("-" = stdin, e.g. run_scan.sh -o ids)
   -x <what>    collect exclusion, repeatable: weights | check_points | <rsync pattern>
                  weights      — check_points/ + *.jax  (eval/adaptation runs: logs only)
                  check_points — check_points/ only     (training runs: final weights kept)
   -D <path>    collect destination, RELATIVE TO THE PROJECT ROOT — default is
                the run store above the repo (artifacts/runs/{project}/).
                Use it to land run dirs straight in their promoted home, e.g.
                -D outputs/models/pretraining/seed0/xferqoe
   -n           dry run — list what rsync would transfer, change nothing
   -f           distribute only: clear remote models/ before transfer
   -h           show help
```

## Procedure

1. Check the current server info in `md_files/users/users.yaml`.
2. Ask the user for the option values needed.
3. Run `.claude/skills/artifact_sync/scripts/artifact_sync.sh` with the options the user confirmed.

## Path model — fixed lanes per direction, not arbitrary paths

`-t`/`-r` select the **target**; the path is decided by the mode. Only collect can change the destination, with `-D`.

| Mode | Source → destination | Location |
|------|----------------------|----------|
| **collect** | remote `artifacts/runs/{project}/` → local `artifacts/runs/{project}/` | **outside** the repo (sibling of the project directory) |
| **collect `-D <path>`** | remote `artifacts/runs/{project}/` → local `{project}/<path>/` | `<path>` is **relative to the project root**; absolute paths are rejected |
| **distribute** | local `{project}/outputs/models/` → remote same path | **inside** the repo |

- Always runs only on a `sync_hub=true` server. **Parallel** per server, via staging (`runs_staging/{project}_{server}/`) then mv.
- **The source is never deleted in either direction.** `rsync` carries no `--remove-source-files`/`--delete`. The only destructive action is `distribute -f` emptying the destination.
- On mv failure it stays in staging (`... kept in <staging>`). Check it directly at that path.

## Reading the exit message and exit code

collect always prints, at the end, a **run_id → source server** table and the **requested ids that existed on no server**.

| Last line | Meaning | rc |
|-----------|---------|---:|
| `completed successfully` | everything requested was transferred | 0 |
| `completed with gaps` | a server went uninspected so no verdict is possible, or an id could not be found for that reason | 0 |
| `FAILED — … exist nowhere` | every server was inspected and the requested id is absent (definitive) | 1 |
| `FAILED — see the per-server logs` | rsync/finalize failed = the transfer itself did not happen | 1 |
| `no server matched -t '<x>'` | nothing was inspected — a `-t` mistake. **A sync_hub and a non-remote server are never peers** (no reason to collect from the hub to the hub) | 1 |

`[WARN] not inspected` means that server's store **could not be read**, not that a transfer failed. It shows up normally in a fan-out where a few Pis are off, and does not raise rc.

## Common combinations

```bash
# Collect a finished run straight into the promotion path (replaces a hand rsync)
./artifact_sync.sh -a c -p <project> -t all -r <run_id> \
    -D outputs/models/pretraining/seed0/<method>

# Pipe run_scan output through to collect only the logs (adaptation/eval)
<run_scan -o ids> | ./artifact_sync.sh -a c -p <project> -t all -R - -x weights

# Only show what would move (changes nothing)
./artifact_sync.sh -a c -p <project> -t all -r <run_id> -n
```

The run_id → server table printed after collection is the basis for the `source server` column in each domain's `runs_map` — do not memorize it by hand; copy this output over.
