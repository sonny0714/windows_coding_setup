---
description: "Monitor — multi-server CPU/GPU dashboard in one tmux session"
disable-model-invocation: false
user-invocable: true
argument-hint: [server]
allowed-tools: Bash(*)
---

Run `.claude/skills/monitor/scripts/monitor.sh`.

## Important: always confirm the options with the user before running

**Never decide the options on your own and run immediately.**
Refer to the option information below, ask the user for the option values needed, then run.

### Usage
```
 Usage:
   ./monitor.sh                       — GPU group, two columns, attach
   ./monitor.sh -g pi                 — Pi/CPU group, tiled grid, attach
   ./monitor.sh -m combo              — force nvidia-smi + top combo watch
   ./monitor.sh -m nvitop             — nvitop only (no fallback)
   ./monitor.sh -m gpu                — plain `watch nvidia-smi` (old behavior)
   ./monitor.sh -m htop               — htop only (CPU focus)
   ./monitor.sh -l "z3,ada2,z4" -r "th1,n2,deep"   — custom columns
   ./monitor.sh -K                    — kill the GPU session ("mon")
   ./monitor.sh -g pi -K              — kill the Pi session ("mon_pi")
```

### Options
```
 Options:
   -g <group>  gpu (default) | pi
                 gpu → servers WITH a gpu_available_list, two columns,
                       session "mon", default mode auto
                 pi  → active remote servers with NO gpu, tiled grid,
                       session "mon_pi", default mode cpu
   -m <mode>   auto | combo | nvitop | nvtop | gpu | htop | cpu
                 auto  → nvitop, else nvtop, else combo watch
                 combo → watch: nvidia-smi + load + top CPU procs
                 gpu   → watch nvidia-smi
                 htop  → htop
                 cpu   → compact 5-line CPU% / MEM% / temp+load /
                         physical link (iface, signal, PHY rate, channel) /
                         live rx-tx throughput + wifi retry delta (no deps)
   -l <list>   comma-separated LEFT column servers  (pi: whole list)
   -r <list>   comma-separated RIGHT column servers (unused for pi)
   -n <name>   tmux session name (default: per group — mon / mon_pi)
   -w <name>   tmux window name (default: per group — mon / pi)
   -k          kill an existing session of the same name first, then recreate
   -K          kill the whole session and EXIT (terminate its panes at once)
   -h          show help
```

## Procedure

1. Check the current server info in `md_files/users/users.yaml`.
2. Ask the user for the option values needed.
3. Run `.claude/skills/monitor/scripts/monitor.sh` with the options the user confirmed.
