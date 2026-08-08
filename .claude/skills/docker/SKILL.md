---
description: "Manage docker containers on remote servers — container start/stop/pull"
disable-model-invocation: false
user-invocable: true
argument-hint: [image] [server]
allowed-tools: Bash(*)
---

Run `.claude/skills/docker/scripts/docker.sh`.

## Important: always confirm the options with the user before running

**Never decide the options on your own and run immediately.**
Refer to the option information below, ask the user for the option values needed, then run.

### Usage
```
 Usage:
   ./docker.sh -i <image> -t all              — start missing on all eligible servers
   ./docker.sh -i <image> -t all -f           — force restart on non-push servers
   ./docker.sh -i <image> -t <server>         — start missing on specific server
   ./docker.sh -i <image> -t <server> -f      — force restart on specific server
   ./docker.sh -i <image> -t <server> -g <n>  — only that GPU's container
   ./docker.sh -i <img> -t <srv> -g 0 -n b    — extra container beside {img}_0_*
```

### Options
```
 Options:
   -i <image>   target docker image — required
                  must be in the target server's docker_available_list
                  (defaults already merged in by yaml_to_bash.py)
   -t <server>  target server — required ("all" = common rule)
   -g <gpu_id>  restrict to ONE gpu — handles only "{image}_{gpu_id}_{PROJECT_USER}"
                and skips the _test container. Needs a single -t <server>
                (gpu ids are per-server) and a gpu in its gpu_available_list
   -n <tag>     name tag appended to the gpu id → "{image}_{gpu_id}{tag}_{PROJECT_USER}"
                (-g 0 -n b → netai_0b_sonny), so a dedicated container can sit
                beside a busy one on the same gpu. Requires -g; [a-z0-9] only
   -f           force: stop containers, pull image, restart all containers
                without -f: only pull/start containers that are not running
                with -t all: also drops push servers of any project (protective)
   -h           show help
```

## Procedure

1. Check the current server info in `md_files/users/users.yaml`.
2. Ask the user for the option values needed.
3. Run `.claude/skills/docker/scripts/docker.sh` with the options the user confirmed.

## 🔴 Restart Guard — mandatory checks before you stop/restart an existing container

**`-f` (force), `docker restart`, and `docker stop` kill every process inside the container.** Even when the goal is to recover from a GPU error (NVML "Unknown Error"), before restarting an existing container you MUST:

1. **Check for a live run** — `docker exec <container> pgrep -af python` (via ssh if remote). If a process exists, also `tail` the log to confirm it is actually progressing (an error loop / zombie may be restarted).
2. **Cross-check the `md_files/users/{user}/run/_index.md` Active table** — see whether a `running` experiment occupies that container slot.
3. **If a live run exists, do not restart** — leave the broken container alone and **create a new container** on a healthy GPU to launch the new experiment: `./docker.sh -i <image> -t <server> -g <gpu_id>` (`--shm-size`/`--memory-swappiness=0` are applied automatically by docker.sh). Then reflect the new slot in `run/_index.md`.

> **One GPU ≠ one container.** A single GPU can hold **up to 4** containers. If the default name `{image}_{gpu}_{user}` is already in use, do not restart it — bring up **an additional container with a different name on the same GPU** via `-n <tag>`: `./docker.sh -i <image> -t <server> -g 0 -n b` → `netai_0b_sonny`. Do not `docker run` by hand — `--shm-size`/`--memory-swappiness=0`/`--init` are attached automatically.

Full decision rules: `md_files/agent.md` → "GPU-Broken Container With a Live Run". Since several sessions share one server, **"this session launched no run" ≠ "the container is empty"** — always base the check on the container's actual state.
