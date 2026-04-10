"""Worklog pipeline: staging parsing, daily append, weekly summary generation."""

import argparse
import datetime
import os
from pathlib import Path

import yaml

WORKLOG_DIR = Path(__file__).resolve().parent.parent
CONFIG_PATH = WORKLOG_DIR / "config.yaml"
USERS_PATH = WORKLOG_DIR / "users.yaml"


def load_config():
    with open(CONFIG_PATH) as f:
        return yaml.safe_load(f)


def get_user_dir(username):
    """Get user's worklog directory."""
    return WORKLOG_DIR / username


def get_kst_now():
    """Get current time in KST (UTC+9)."""
    kst = datetime.timezone(datetime.timedelta(hours=9))
    return datetime.datetime.now(kst)


def get_today_date(config):
    """Get today's date considering day_boundary_hour."""
    now = get_kst_now()
    boundary = config["daily"]["day_boundary_hour"]
    if now.hour < boundary:
        return (now - datetime.timedelta(days=1)).strftime("%Y-%m-%d")
    return now.strftime("%Y-%m-%d")


def get_daily_path(config, username, date_str=None):
    """Get path to daily file for a specific user."""
    if date_str is None:
        date_str = get_today_date(config)
    fmt = config["daily"]["filename_format"].format(date=date_str)
    return get_user_dir(username) / config["paths"]["daily"] / fmt


def get_last_weekly_end(config, username):
    """Find end date of the most recent weekly report."""
    weekly_dir = get_user_dir(username) / config["paths"]["weekly"]
    if not weekly_dir.exists():
        return None
    files = sorted(weekly_dir.glob("*_week.md"))
    if not files:
        return None
    last_file = files[-1].stem.replace("_week", "")
    parts = last_file.split("_")
    if len(parts) >= 2:
        return datetime.date.fromisoformat(parts[-1])
    else:
        return datetime.date.fromisoformat(parts[0]) + datetime.timedelta(days=6)


def get_week_range(config, username, ref_date=None):
    """Get range from last weekly end+1 to ref_date-1 (exclude today)."""
    if ref_date is None:
        ref_date = get_kst_now().date()
    elif isinstance(ref_date, str):
        ref_date = datetime.date.fromisoformat(ref_date)
    week_end = ref_date - datetime.timedelta(days=1)
    last_end = get_last_weekly_end(config, username)
    if last_end is not None:
        week_start = last_end + datetime.timedelta(days=1)
    else:
        daily_dir = get_user_dir(username) / config["paths"]["daily"]
        if daily_dir.exists():
            daily_files = sorted(daily_dir.glob("*.md"))
            if daily_files:
                week_start = datetime.date.fromisoformat(daily_files[0].stem)
            else:
                week_start = week_end
        else:
            week_start = week_end
    return week_start, week_end


def parse_staging(username):
    staging_path = get_user_dir(username) / "staging.md"
    if not staging_path.exists():
        print(f"staging.md not found for user {username}")
        return []
    items = []
    in_comment = False
    with open(staging_path) as f:
        for line in f:
            stripped = line.rstrip()
            if not in_comment and "<!--" in stripped:
                in_comment = True
            if in_comment:
                if "-->" in stripped:
                    in_comment = False
                continue
            if not stripped or stripped.startswith("#"):
                continue
            raw = line.rstrip("\n")
            tab_count = 0
            i = 0
            while i < len(raw):
                if raw[i] == "\t":
                    tab_count += 1
                    i += 1
                elif raw[i:i+4] == "    ":
                    tab_count += 1
                    i += 4
                else:
                    break
            text = raw[i:].lstrip("- ").strip()
            if text:
                items.append({"level": tab_count, "text": text})
    return items


def show_staging(username):
    items = parse_staging(username)
    if not items:
        print("(staging is empty)")
        return
    for item in items:
        indent = "\t" * item["level"]
        print(f"{indent}- {item['text']}")


def read_backlog(username):
    backlog_path = get_user_dir(username) / "backlog.md"
    if not backlog_path.exists():
        return []
    lines = []
    in_comment = False
    for line in backlog_path.read_text().splitlines():
        stripped = line.strip()
        if "<!--" in stripped:
            in_comment = True
        if in_comment:
            if "-->" in stripped:
                in_comment = False
            continue
        if stripped.startswith("#") or not stripped:
            continue
        lines.append(line.rstrip())
    return lines


def clear_staging(username):
    staging_path = get_user_dir(username) / "staging.md"
    backlog_items = read_backlog(username)
    with open(staging_path, "w") as f:
        f.write("# Staging\n\n")
        f.write("<!-- Write tasks to execute below -->\n")
        f.write("<!-- Use tabs to separate sub-levels -->\n")
        f.write(f"<!-- Run: /worklog:{username}:run-staging → execute items, record to daily, clear staging -->\n")
        f.write("<!-- Example:\n- modify gym env\n\t- change observation space\n\t\t- add network state\n\t- update reward function\n- verify trace_sim build\n-->\n")
        if backlog_items:
            f.write("\n<!-- [backlog] upcoming tasks (not executed, managed in backlog.md)\n")
            for item in backlog_items:
                f.write(f"{item}\n")
            f.write("-->\n")
    print(f"staging.md cleared for {username}")


def ensure_daily(config, username, date_str=None):
    path = get_daily_path(config, username, date_str)
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        if date_str is None:
            date_str = get_today_date(config)
        with open(path, "w") as f:
            f.write(f"# {date_str}\n\n")
        print(f"Created: {path.name}")
    return path


def append_daily(config, username, text, level=0, date_str=None):
    path = ensure_daily(config, username, date_str)
    indent = "\t" * level
    with open(path, "a") as f:
        f.write(f"{indent}- {text}\n")
    print(f"Appended to {path.name}: {'  ' * level}- {text}")


def append_daily_block(config, username, lines, date_str=None):
    path = ensure_daily(config, username, date_str)
    with open(path, "a") as f:
        for line in lines:
            f.write(line + "\n")
    print(f"Appended {len(lines)} lines to {path.name}")


def show_daily(config, username, date_str=None):
    path = get_daily_path(config, username, date_str)
    if path.exists():
        print(path.read_text())
    else:
        print(f"No daily file for {date_str or get_today_date(config)}")


def collect_weekly(config, username, ref_date=None):
    week_start, week_end = get_week_range(config, username, ref_date)
    entries = {}
    current = week_start
    while current <= week_end:
        date_str = current.isoformat()
        path = get_daily_path(config, username, date_str)
        if path.exists():
            entries[date_str] = path.read_text()
        current += datetime.timedelta(days=1)
    return week_start, week_end, entries


def generate_weekly_skeleton(config, username, ref_date=None):
    week_start, week_end, entries = collect_weekly(config, username, ref_date)
    week_file = get_user_dir(username) / config["paths"]["weekly"] / f"{week_start.isoformat()}_{week_end.isoformat()}_week.md"
    week_file.parent.mkdir(parents=True, exist_ok=True)
    day_names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    lines = [
        f"# Weekly Report: {week_start.isoformat()} ~ {week_end.isoformat()}",
        "", "## Daily Entries", "",
    ]
    if not entries:
        lines.append("(no daily entries found for this week)")
    else:
        for date_str, content in sorted(entries.items()):
            d = datetime.date.fromisoformat(date_str)
            day_name = day_names[d.weekday()]
            lines.append(f"### {date_str} ({day_name})")
            lines.append("")
            for line in content.splitlines():
                if line.startswith("#"):
                    continue
                if line.strip():
                    lines.append(line)
            lines.append("")
    lines.extend(["## Summary", "", "<!-- Claude will auto-generate the summary -->", ""])
    with open(week_file, "w") as f:
        f.write("\n".join(lines))
    print(f"Weekly skeleton: {week_file}")
    return week_file


def main():
    parser = argparse.ArgumentParser(description="Worklog pipeline")
    parser.add_argument("--user", "-u", required=True, help="Username")
    sub = parser.add_subparsers(dest="command")
    sub.add_parser("staging-show", help="Show parsed staging items")
    sub.add_parser("staging-clear", help="Clear staging.md")
    sub.add_parser("daily-ensure", help="Ensure today's daily file exists")
    d_append = sub.add_parser("daily-append", help="Append item to daily")
    d_append.add_argument("text", help="Text to append")
    d_append.add_argument("--level", type=int, default=0, help="Indent level")
    d_append.add_argument("--date", default=None, help="Target date (YYYY-MM-DD)")
    d_show = sub.add_parser("daily-show", help="Show daily file")
    d_show.add_argument("--date", default=None, help="Date (YYYY-MM-DD)")
    w_gen = sub.add_parser("weekly-generate", help="Generate weekly report skeleton")
    w_gen.add_argument("--date", default=None, help="Reference date (YYYY-MM-DD)")
    w_collect = sub.add_parser("weekly-collect", help="Show collected weekly entries")
    w_collect.add_argument("--date", default=None, help="Reference date (YYYY-MM-DD)")
    sub.add_parser("list-users", help="List registered users")
    args = parser.parse_args()
    config = load_config()
    username = args.user
    if args.command == "list-users":
        for u in config.get("registered_users", []):
            print(u)
    elif args.command == "staging-show":
        show_staging(username)
    elif args.command == "staging-clear":
        clear_staging(username)
    elif args.command == "daily-ensure":
        ensure_daily(config, username)
    elif args.command == "daily-append":
        append_daily(config, username, args.text, args.level, args.date)
    elif args.command == "daily-show":
        show_daily(config, username, args.date)
    elif args.command == "weekly-generate":
        generate_weekly_skeleton(config, username, args.date)
    elif args.command == "weekly-collect":
        _, _, entries = collect_weekly(config, username, args.date)
        for date_str, content in sorted(entries.items()):
            print(f"=== {date_str} ===")
            print(content)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
