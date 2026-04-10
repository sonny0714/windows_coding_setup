---
description: "Git operations across servers — pull / clone -f / push_all on a parent project or a single submodule (-s), with docker chown"
disable-model-invocation: false
user-invocable: true
argument-hint: [action] [project] [submodule?] [server] [message?]
allowed-tools: Bash(*)
---

`.claude/skills/git/scripts/git.sh`을 실행합니다.

## 중요: 실행 전 반드시 사용자에게 옵션을 확인하세요

**절대로 옵션을 임의로 결정하여 바로 실행하지 마세요.**
아래 옵션 정보를 참고하여, 사용자에게 필요한 옵션 값을 질문한 후 실행하세요.

### Usage
```
 Usage (parent project):
   ./git.sh -a pull  -p <project> -t all
   ./git.sh -a pull  -p <project> -t <server>
   ./git.sh -a clone -p <project> -t all     -f
   ./git.sh -a clone -p <project> -t <server> -f
   ./git.sh -a push_all -p <project> -m "msg"

 Usage (single submodule of a project — same actions, just add -s):
   ./git.sh -a pull  -p <project> -s <submodule> -t all
   ./git.sh -a clone -p <project> -s <submodule> -t <server> -f
   ./git.sh -a push_all -p <project> -s <submodule> -m "msg"
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
   -f              clone only: explicit acknowledgement that clone is destructive
   -h              show help
```

## 실행 절차

1. `md_files/worklog/users.yaml`에서 현재 서버 정보를 확인합니다.
2. 사용자에게 필요한 옵션 값을 질문합니다.
3. 사용자가 확인한 옵션으로 `.claude/skills/git/scripts/git.sh`을 실행합니다.
