# Run Log — sonny

<!-- Long-running remote processes (started via `docker exec -d`) tracked here. -->
<!-- claude reads this file to check status; users can copy `check_cmd` / `tail_cmd` to verify manually. -->
<!--
Ordering: newest entry on TOP (prepend on insert).
  → currently running [running] entries stay visible without scrolling;
  → finished [done] / [failed] entries naturally sink as history archive.

Section header convention:
  ## [running]   — process still alive
  ## [done]      — finished successfully
  ## [failed]    — finished with error / killed

Required fields per entry:
  - server, container, started, expected_duration, next_check_after
  - command, log_path, result_path
  - check_cmd, tail_cmd

Log path convention:
  {target_mnt_path}/tee_log/{project_name}/{YYYYMMDD-HHMMSS}.log
  → on host: {source_mnt_path}/tee_log/{project_name}/{YYYYMMDD-HHMMSS}.log
  → mounted, so docker storage does not grow.
-->

<!-- Example entry (delete when first real entry is added) -->
<!--
## [running] example_run
- server: <server_name>
- container: <container_name>
- started: YYYY-MM-DD HH:MM:SS KST
- expected_duration: ~2h
- next_check_after: YYYY-MM-DD HH:MM:SS KST
- command: `python3 -u path/to/script.py --args`
- log_path: {target_mnt_path}/tee_log/{project_name}/{YYYYMMDD-HHMMSS}.log
- result_path: path/to/output_dir/
- check_cmd: `ssh <server> "docker exec <container> pgrep -f script.py >/dev/null && echo running || echo done"`
- tail_cmd: `ssh <server> "docker exec <container> tail -20 {log_path}"`
-->
