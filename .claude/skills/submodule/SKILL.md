---
description: "Submodule — backup/restore + convert between tracked files and git submodule"
disable-model-invocation: false
user-invocable: true
---

`.claude/skills/submodule/scripts/submodule.sh`을 실행합니다.

## 중요: 실행 전 반드시 사용자에게 옵션을 확인하세요

**절대로 옵션을 임의로 결정하여 바로 실행하지 마세요.**
아래 옵션 정보를 참고하여, 사용자에게 필요한 옵션 값을 질문한 후 실행하세요.

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

## 실행 절차

1. `md_files/worklog/users.yaml`에서 현재 서버 정보를 확인합니다.
2. 사용자에게 필요한 옵션 값을 질문합니다.
3. 사용자가 확인한 옵션으로 `.claude/skills/submodule/scripts/submodule.sh`을 실행합니다.
