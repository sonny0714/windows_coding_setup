#!/usr/bin/env python3
"""Scan a runs root and emit one TSV row per run dir: server, run_id, mtime, status, keys."""

import argparse
import fnmatch
import glob
import json
import os
import re
import sys
import time

RELATIVE_SINCE = re.compile(r"^(\d+)([mhd])$")
SECONDS_PER = {"m": 60, "h": 3600, "d": 86400}
COMPARATORS = {">=": lambda a, b: a >= b, "==": lambda a, b: a == b, ">": lambda a, b: a > b}
MISSING = object()
EMPTY = "-"


def parse_since(text):
    relative = RELATIVE_SINCE.match(text)
    if relative:
        return time.time() - int(relative.group(1)) * SECONDS_PER[relative.group(2)]
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d"):
        try:
            return time.mktime(time.strptime(text, fmt))
        except ValueError:
            continue
    raise SystemExit("[run_scan] unparsable --since (want 6h / 2d / 30m / 'YYYY-MM-DD HH:MM'): %s" % text)


def parse_done(spec):
    if spec.startswith("file:"):
        return ("file", spec[5:].strip(), None, 0)
    if spec.startswith("glob:"):
        body = spec[5:]
        for op in (">=", "==", ">"):
            if op in body:
                pattern, bound = body.split(op, 1)
                return ("glob", pattern.strip(), op, int(bound))
        return ("glob", body.strip(), ">=", 1)
    raise SystemExit("[run_scan] unparsable --done (want file:<path> or glob:<pat><op><n>): %s" % spec)


def parse_match(spec):
    if "=" not in spec:
        raise SystemExit("[run_scan] unparsable --match (want key=value): %s" % spec)
    key, value = spec.split("=", 1)
    return (key.strip(), value.strip())


def config_get(config, key):
    """Dotted key lookup — flat 'a.b.c' entry first, then a nested walk."""
    if key in config:
        return config[key]
    node = config
    for part in key.split("."):
        if not isinstance(node, dict) or part not in node:
            return MISSING
        node = node[part]
    return node


def as_text(value):
    if value is MISSING:
        return EMPTY
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def evaluate(run_dir, predicates):
    """Return (is_done, status_label) for one run dir."""
    if not predicates:
        return (False, EMPTY)
    failures = []
    for kind, target, op, bound in predicates:
        if kind == "file":
            if not os.path.exists(os.path.join(run_dir, target)):
                failures.append("no:%s" % target)
        else:
            found = len(glob.glob(os.path.join(run_dir, target)))
            if not COMPARATORS[op](found, bound):
                failures.append("%s(%d/%d)" % (os.path.basename(target), found, bound))
    if failures:
        return (False, "partial " + " ".join(failures))
    return (True, "done")


def scan(args):
    predicates = [parse_done(spec) for spec in args.done]
    matches = [parse_match(spec) for spec in args.match]
    cutoff = parse_since(args.since) if args.since else None

    rows = []
    for entry in sorted(os.listdir(args.root)):
        run_dir = os.path.join(args.root, entry)
        if not os.path.isdir(run_dir):
            continue
        mtime = os.path.getmtime(run_dir)
        if cutoff is not None and mtime < cutoff:
            continue

        config_path = os.path.join(run_dir, args.config)
        config = None
        if os.path.isfile(config_path):
            try:
                with open(config_path) as handle:
                    config = json.load(handle)
            except (ValueError, OSError):
                config = None
        # A run whose config is unreadable cannot be filtered, so a filtered scan
        # drops it while an unfiltered readback still reports the dir.
        if config is None:
            if matches:
                continue
            config = {}

        if any(not fnmatch.fnmatch(as_text(config_get(config, key)), pattern) for key, pattern in matches):
            continue

        _, status = evaluate(run_dir, predicates)
        columns = [
            args.server,
            entry,
            time.strftime("%Y-%m-%d %H:%M", time.localtime(mtime)),
            status,
        ]
        columns.extend(as_text(config_get(config, key)) for key in args.key)
        rows.append((mtime, entry, columns))

    rows.sort(key=lambda row: (row[0], row[1]))
    for _, _, columns in rows:
        print("\t".join(columns))


def main():
    parser = argparse.ArgumentParser(prog="run_scan", description="Scan experiment run dirs.")
    parser.add_argument("--root", required=True, help="runs root (artifacts/runs/<project>)")
    parser.add_argument("--server", default=EMPTY, help="server label stamped into column 1")
    parser.add_argument("--config", default="config.json", help="per-run config filename")
    parser.add_argument("--since", help="6h / 2d / 30m / 'YYYY-MM-DD HH:MM'")
    parser.add_argument("--match", action="append", default=[], help="config key=value filter (glob)")
    parser.add_argument("--key", action="append", default=[], help="extra config key column")
    parser.add_argument("--done", action="append", default=[], help="file:<path> or glob:<pat><op><n>")
    args = parser.parse_args()

    if not os.path.isdir(args.root):
        return 0
    scan(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
