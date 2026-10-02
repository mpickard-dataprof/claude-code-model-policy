#!/usr/bin/env bash
# Fast status-line helper. Reads one Claude Code status JSON object on stdin and
# atomically refreshes this installation's usage snapshot; it is intentionally
# silent and never makes a status line fail.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SNAPSHOT="${MODEL_POLICY_USAGE_SNAPSHOT:-$ROOT/usage.json}"
INPUT="$(cat 2>/dev/null || true)"
python3 - "$SNAPSHOT" "$INPUT" <<'PY' >/dev/null 2>&1 || true
import json, os, sys, tempfile, time
try:
    limits = json.loads(sys.argv[2]).get("rate_limits") or {}
    five = (limits.get("five_hour") or {}).get("used_percentage")
    seven = (limits.get("seven_day") or {}).get("used_percentage")
    if five is None and seven is None: raise SystemExit
    out = {"ts": int(time.time())}
    if isinstance(five, (int, float)): out["five_hour_pct"] = five
    if isinstance(seven, (int, float)): out["seven_day_pct"] = seven
    fd, temp = tempfile.mkstemp(prefix=".usage.", dir=os.path.dirname(sys.argv[1]))
    with os.fdopen(fd, "w") as f: json.dump(out, f, separators=(",", ":")); f.write("\n")
    os.replace(temp, sys.argv[1])
except Exception: pass
PY
exit 0
