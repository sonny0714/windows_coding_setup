# User: sonny

language: ko

User-specific rules and preferences for sonny.
Global rules are in `md_files/claude.md`.

## Worklog Commands

- `/worklog:sonny:staging` — Start staging session
- `/worklog:sonny:run-staging` — Execute staging items and record to daily
- `/worklog:sonny:weekly-report` — Generate weekly report

## Project Docker Containers (auto-generated)

<!-- alias:project_docker:start -->
Docker images for project `windows_coding_setup` and user `sonny`. Generated from `users.yaml` by `worklog_setup.sh` (each user can have different images per project).

| Image | Source | Containers (this user) |
|-------|--------|------------------------|
| `base` (default) | `sonny0714/base:22.04` | `base_sonny` (CPU only) |

**Container naming** (suffix `_sonny`):

- base image → `base_sonny` (CPU only, no GPU)
- other image, allow_push server → `<img>_test_sonny` (GPU 0)
- other image, per GPU → `<img>_<gpu_id>_sonny` (e.g. `<img>_0_sonny`, `<img>_1_sonny`)

This project has no user-specific images mapped — use the default `base_sonny` container.

For full Docker usage rules see `md_files/claude.md` → Docker Environment.
<!-- alias:project_docker:end -->
