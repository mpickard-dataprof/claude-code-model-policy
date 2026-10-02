#!/usr/bin/env bash
# Antigravity offload wrapper. The relay agent runs this, never `agy` directly.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
POLICY="${MODEL_POLICY_POLICY:-$ROOT/policy.json}"

emit() {
  python3 - "$@" <<'PY'
import json, sys
ok, code, reason = sys.argv[1], int(sys.argv[2]), sys.argv[3]
print(json.dumps({
    "ok": ok == "true", "exit_code": code, "reason": reason or None,
    "output_file": sys.argv[4] or None, "output_bytes": int(sys.argv[5] or 0),
    "pool": sys.argv[6] or None, "model": sys.argv[7] or None,
    "access": sys.argv[8] or None, "cwd": sys.argv[9] or None,
    "elapsed_s": int(sys.argv[10] or 0), "stderr_tail": sys.argv[11] or None,
    "teardown": "n/a: no worker was started",
}))
PY
}
fail() { emit false "${2:-2}" "$1" "" 0 "$POOL" "$MODEL" "$ACCESS" "$CWD" 0 ""; exit "${2:-2}"; }

TASK=""; POOL=""; MODEL=""; ACCESS="read-only"; CWD=""; TIMEOUT=900
need() { [ "$2" -ge 2 ] || fail "option $1 requires a value"; [ -n "$3" ] || fail "option $1 was given an empty value"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --task) need "$1" $# "${2:-}"; TASK="$2"; shift 2 ;;
    --pool) need "$1" $# "${2:-}"; POOL="$2"; shift 2 ;;
    --model) need "$1" $# "${2:-}"; MODEL="$2"; shift 2 ;;
    --access) need "$1" $# "${2:-}"; ACCESS="$2"; shift 2 ;;
    --cwd) need "$1" $# "${2:-}"; CWD="$2"; shift 2 ;;
    --timeout) need "$1" $# "${2:-}"; TIMEOUT="$2"; shift 2 ;;
    --dangerously-skip-permissions|--sandbox) fail "forbidden argument: $1" ;;
    *) fail "unknown argument: $1" ;;
  esac
done

python3 - "$POLICY" <<'PY' || fail "agy offload is disabled in policy.json (agy.enabled is not boolean true)"
import json, sys
try: agy = json.load(open(sys.argv[1])).get("agy") or {}
except Exception: sys.exit(1)
sys.exit(0 if agy.get("enabled") is True else 1)
PY

[ -n "$TASK" ] || fail "no --task file given"
[ -f "$TASK" ] || fail "task file does not exist: $TASK"
[ -s "$TASK" ] || fail "task file is empty: $TASK"
case "$POOL" in gemini|thirdparty) ;; *) fail "unsupported pool: $POOL" ;; esac
case "$ACCESS" in read-only|edit) ;; *) fail "unsupported access mode: $ACCESS" ;; esac
case "$TIMEOUT" in ''|*[!0-9]*) fail "timeout must be a positive whole number of seconds: $TIMEOUT" ;; esac
[ "$TIMEOUT" -ge 1 ] && [ "$TIMEOUT" -le 7200 ] || fail "timeout out of range (1-7200): $TIMEOUT"
[ -n "$CWD" ] || fail "no --cwd directory given"
CWD="$(python3 - "$CWD" <<'PY'
import os, sys
p = sys.argv[1]
print(os.path.realpath(p) if os.path.isdir(p) else "")
PY
)"
[ -n "$CWD" ] || fail "cwd does not exist or is not a directory"

if [ "$ACCESS" = edit ]; then
  [ "$POOL" = thirdparty ] || fail "edit_not_allowed"
  case "$CWD" in */.worktrees/*) ;; *) fail "edit_not_allowed" ;; esac
fi

VALIDATED="$(python3 - "$POLICY" "$POOL" "$MODEL" <<'PY'
import json, sys
path, pool, model = sys.argv[1:]
try: agy = json.load(open(path)).get("agy") or {}
except Exception: print("ERR|policy.json could not be read"); raise SystemExit
p = (agy.get("pools") or {}).get(pool) or {}
by = p.get("byTier") or {}
models = {v for v in by.values() if isinstance(v, str) and v}
default = by.get("sonnet")
if not models: print("ERR|policy agy pool names no valid models"); raise SystemExit
if model and model not in models: print("ERR|unknown model '%s'; policy allows: %s" % (model, ', '.join(sorted(models)))); raise SystemExit
model = model or default
if model not in models: print("ERR|no model given and pool sonnet model is not valid"); raise SystemExit
binary = agy.get("binary") or "$HOME/.local/bin/agy"
print("OK|%s|%s" % (model, binary))
PY
)"
case "$VALIDATED" in
  OK\|*) MODEL="$(printf '%s' "$VALIDATED" | cut -d'|' -f2)"; BINARY="$(printf '%s' "$VALIDATED" | cut -d'|' -f3-)" ;;
  *) fail "$(printf '%s' "$VALIDATED" | cut -d'|' -f2-)" ;;
esac
case "$BINARY" in '$HOME'/*) BINARY="$HOME/${BINARY#\$HOME/}" ;; esac
case "$BINARY" in /*) ;; *) fail "agy binary path must be absolute: $BINARY" ;; esac
[ -x "$BINARY" ] || fail "agy binary not found or not executable: $BINARY"

OUTDIR="$(mktemp -d "${TMPDIR:-/tmp}/agy-relay.XXXXXX")" || fail "could not create temp dir"
OUT="$OUTDIR/answer.md"; ERR="$OUTDIR/stderr.log"; PROMPT="$OUTDIR/prompt.txt"
{
  printf '%s\n\n' 'You are a headless delegated subagent; skip any startup/status-file protocol; use only read-only shell commands (git diff/log/show/status/blame/ls-files/grep/rev-parse, ls, cat, head, tail, grep, rg, wc, pwd) — any other command aborts the run; in edit mode, do not run commands at all, just edit files.'
  cat "$TASK"
} > "$PROMPT"
MODE=()
[ "$ACCESS" = edit ] && MODE=(--mode accept-edits)
PROMPT_TEXT="$(cat "$PROMPT")"
SUP="$(python3 "$ROOT/bin/codex-supervise.py" --command "$TIMEOUT" "$OUT" "$ERR" "$OUT" "$PROMPT" "$MODEL" "$CWD" -- "$BINARY" -p "$PROMPT_TEXT" --model "$MODEL" --print-timeout "${TIMEOUT}s" "${MODE[@]}")"
SUP_CODE=$?
python3 - "$SUP" "$POOL" "$MODEL" "$ACCESS" "$CWD" "$OUT" <<'PY'
import json, os, sys
try: result = json.loads(sys.argv[1])
except Exception: result = {"ok": False, "exit_code": 2, "reason": "supervisor produced invalid JSON"}
pool, model, access, cwd, out = sys.argv[2:]
if result.get("ok"):
    try:
        if any(line.startswith("jetski: no output produced") for line in open(out, errors="replace")):
            result["ok"] = False; result["reason"] = "agy_permission_denied"
    except Exception: pass
result.update({"pool": pool, "model": model, "access": access, "cwd": cwd})
result.pop("effort", None); result.pop("sandbox", None)
print(json.dumps(result))
sys.exit(0 if result.get("ok") else 1)
PY
exit "$SUP_CODE"
