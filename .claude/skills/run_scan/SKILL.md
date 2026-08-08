---
description: "Discover experiment run dirs across servers — run_id readback, config filter, completion status, wait-until-done"
disable-model-invocation: false
user-invocable: true
argument-hint: [project] [server] [since?] [match?]
allowed-tools: Bash(*)
---

Run `.claude/skills/run_scan/scripts/run_scan.sh`.

## Run it right away

This skill is **read-only** — it writes nothing, moves nothing, deletes nothing.
Do not reconfirm options with the user — decide the options you need from the information below and run it right away.

### Usage
```
 Usage:
   ./run_scan.sh -p <project> -t all                       — every run dir on all active servers
   ./run_scan.sh -p <project> -t <server> -s 6h            — only dirs modified in the last 6h
   ./run_scan.sh -p <project> -t all -m model.core.algo_name=vanilla_sac
   ./run_scan.sh -p <project> -t all -d file:finished -o md
   ./run_scan.sh -p <project> -t all -d file:finished -w 30
   ./run_scan.sh -p <project> -t all -d file:finished -D -o ids | artifact_sync.sh -a c -p <project> -t all -R -
```

### Options
```
 Options:
   -p <project> target project — required
   -t <server>  target server — required ("all" = all active servers, incl. this one)
   -s <since>   only dirs modified after: 6h / 2d / 30m / "YYYY-MM-DD HH:MM"
   -m <k=v>     config.json filter, repeatable (AND); value accepts a * glob
   -k <key>     extra config.json key printed as a column, repeatable
   -d <spec>    completion predicate, repeatable:
                  file:online.jax             — path exists inside the run dir
                  glob:rollout/iter*.npz>=200 — glob count meets the bound
   -D           keep only rows whose status is done (needs -d)
   -w <n>       block until n runs report done, then print (needs -d)
   -i <sec>     poll interval for -w (default 240)
   -o <fmt>     output format: tsv (default) | md | ids
   -c <name>    per-run config filename (default config.json)
   -h           show help
```

## Procedure

1. Decide the options you need from the Options section below.
2. Run `.claude/skills/run_scan/scripts/run_scan.sh`.
