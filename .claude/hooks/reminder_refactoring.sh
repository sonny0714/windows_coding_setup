#!/usr/bin/env bash
# Fires before Edit/Write — reminds to read the matching refactoring.md first.
# Two ways a topic is matched:
#   A) the edited file lives under md_files/refactoring/{topic}/   (plan/backup edits)
#   B) the edited *source* file path matches an active topic's scope prefix,
#      read from md_files/refactoring/_index.md  (hook-registry block).
# (B) is the important case: real refactoring edits touch source trees
# (args/, learning_frameworks/jax_layer/, ...) that do NOT live under
# md_files/refactoring/, so a literal path match alone never fires for them.

input=$(cat)

INPUT="$input" PROJ="${CLAUDE_PROJECT_DIR:-}" python3 - <<'PY' >&2
import sys, os, json, re

data = json.loads(os.environ.get("INPUT", "") or "{}")
fp = data.get("tool_input", {}).get("file_path", "") or ""
if not fp:
    sys.exit(0)

def emit(topic):
    print(f"[refactoring trigger] {fp}")
    print(f"  -> active refactoring topic: {topic}")
    print(f"  - read md_files/refactoring/{topic}/refactoring.md first (if this is the first time this session)")
    print(f"  - check scope / coupled topics in md_files/refactoring/{topic}/_index.md")
    print(f"  - the plan is authoritative — do not re-derive the design or improvise a new direction")
    print(f"  - on phase completion, diff against backup + update the refactoring.md progress notes")

# Case A: editing a file under md_files/refactoring/{topic}/
m = re.search(r"/md_files/refactoring/([^/]+)/", fp)
if m and m.group(1) not in ("backup",):
    emit(m.group(1))
    sys.exit(0)

# Resolve project root: $CLAUDE_PROJECT_DIR, else walk up from fp.
proj = os.environ.get("PROJ", "").rstrip("/")
if not proj:
    d = os.path.dirname(os.path.abspath(fp))
    while d != "/":
        if os.path.isfile(os.path.join(d, "md_files/refactoring/_index.md")):
            proj = d
            break
        d = os.path.dirname(d)

idx = os.path.join(proj, "md_files/refactoring/_index.md") if proj else ""
if not idx or not os.path.isfile(idx):
    sys.exit(0)

rel = fp
if proj and fp.startswith(proj + "/"):
    rel = fp[len(proj) + 1:]

# Parse hook-registry block: lines "topic: prefix1, prefix2"
globs = {}
in_reg = False
with open(idx, encoding="utf-8") as f:
    for line in f:
        s = line.strip()
        if s.startswith("<!-- hook-registry"):
            in_reg = True
            continue
        if in_reg and s.startswith("-->"):
            break
        if in_reg and ":" in s and not s.startswith("#"):
            topic, prefixes = s.split(":", 1)
            topic = topic.strip()
            for p in prefixes.split(","):
                p = p.strip()
                if p:
                    globs[p] = topic

# Longest matching prefix wins (disambiguates shared roots).
best = None
for p, topic in globs.items():
    if rel.startswith(p) and (best is None or len(p) > len(best[0])):
        best = (p, topic)
if best:
    emit(best[1])
PY
exit 0
