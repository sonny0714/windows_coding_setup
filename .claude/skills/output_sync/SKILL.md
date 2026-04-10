---
description: "Sync experiment outputs between servers — collect or distribute via rsync"
disable-model-invocation: false
user-invocable: true
argument-hint: [mode] [project] [server]
allowed-tools: Bash(*)
---

`.claude/skills/output_sync/scripts/output_sync.sh`을 실행합니다.

## 중요: 실행 전 반드시 사용자에게 옵션을 확인하세요

**절대로 옵션을 임의로 결정하여 바로 실행하지 마세요.**
아래 옵션 정보를 참고하여, 사용자에게 필요한 옵션 값을 질문한 후 실행하세요.

### Usage
```
 Usage:
   ./output_sync.sh -a collect -p <project> -t all       — collect save from all active servers
   ./output_sync.sh -a c -p <project> -t all             — short for collect
   ./output_sync.sh -a distribute -p <project> -t all    — distribute load to all active servers
   ./output_sync.sh -a d -p <project> -t all             — short for distribute
   ./output_sync.sh -a c -p <project> -t <server>        — collect from specific server
   ./output_sync.sh -a d -p <project> -t <server> -f     — distribute to server, clear load first
```

### Options
```
 Options:
   -a <mode>    collect (c) or distribute (d) — required
   -p <project> target project — required
   -t <server>  target server — required ("all" = all server_active_status=true servers)
   -f           distribute only: clear remote load/ before transfer
   -h           show help
```

## 실행 절차

1. `md_files/worklog/users.yaml`에서 현재 서버 정보를 확인합니다.
2. 사용자에게 필요한 옵션 값을 질문합니다.
3. 사용자가 확인한 옵션으로 `.claude/skills/output_sync/scripts/output_sync.sh`을 실행합니다.
