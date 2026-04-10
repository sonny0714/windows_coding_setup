---
description: "Manage docker containers on remote servers — container start/stop/pull"
disable-model-invocation: false
user-invocable: true
argument-hint: [image] [server]
allowed-tools: Bash(*)
---

`.claude/skills/docker/scripts/docker.sh`을 실행합니다.

## 중요: 실행 전 반드시 사용자에게 옵션을 확인하세요

**절대로 옵션을 임의로 결정하여 바로 실행하지 마세요.**
아래 옵션 정보를 참고하여, 사용자에게 필요한 옵션 값을 질문한 후 실행하세요.

### Usage
```
 Usage:
   ./docker.sh -i <image> -t all              — start missing on all eligible servers
   ./docker.sh -i <image> -t all -f           — force restart on non-push servers
   ./docker.sh -i <image> -t <server>         — start missing on specific server
   ./docker.sh -i <image> -t <server> -f      — force restart on specific server
```

### Options
```
 Options:
   -i <image>   target docker image — required
                  must be in the target server's docker_available_list
                  (defaults already merged in by yaml_to_bash.py)
   -t <server>  target server — required ("all" = common rule)
   -f           force: stop containers, pull image, restart all containers
                without -f: only pull/start containers that are not running
                with -t all: also drops servers with allow_push=true (protective)
   -h           show help
```

## 실행 절차

1. `md_files/worklog/users.yaml`에서 현재 서버 정보를 확인합니다.
2. 사용자에게 필요한 옵션 값을 질문합니다.
3. 사용자가 확인한 옵션으로 `.claude/skills/docker/scripts/docker.sh`을 실행합니다.
