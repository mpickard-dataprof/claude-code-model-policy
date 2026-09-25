#!/usr/bin/env bash
# Codex offload wrapper.
#
# The relay agent (agents/codex.md) runs THIS, never `codex exec` directly.
# Prose in an agent definition is not an execution boundary: everything that must
# be deterministic — argument construction, path allocation, model and effort
# validation, the sandbox allowlist, the timeout, the exit status — lives here
# where it can be tested.
#
# Usage:
#   codex-relay.sh --task FILE [--model M] [--effort E] [--sandbox MODE]
#                  [--timeout SECS]
#
# Writes the worker's final message to a file and prints ONE line of JSON to
# stdout describing the outcome — on EVERY exit path, including argument errors.
# Never prints the answer itself: the caller reads the output file, so a large
# result cannot be truncated by a pipe buffer.
#
# Requires bash (not sh): `set -o pipefail` is not POSIX, and on Debian/Ubuntu
# /bin/sh is dash, which fails on it before reaching any tested behaviour.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Overridable so the suite can exercise config-dependent behaviour without
# mutating the live policy — the production config is not a test fixture.
POLICY="${MODEL_POLICY_POLICY:-$ROOT/policy.json}"

# --- One serializer, one schema, every exit path -------------------------
# Early failures previously emitted a hand-built `{"ok":false,"error":...}` that
# both omitted the fields the relay is told to read and broke outright when the
# interpolated text contained a quote or a newline.
emit() {
  python3 - "$@" <<'PY'
import json, sys
ok, code, reason = sys.argv[1], int(sys.argv[2]), sys.argv[3]
out = {
    "ok": ok == "true",
    "exit_code": code,
    "reason": reason or None,
    "output_file": sys.argv[4] or None,
    "output_bytes": int(sys.argv[5] or 0),
    "model": sys.argv[6] or None,
    "effort": sys.argv[7] or None,
    "sandbox": sys.argv[8] or None,
    "elapsed_s": int(sys.argv[9] or 0),
    "stderr_tail": sys.argv[10] or None,
    # Present on every result so the field is never missing, only null. These
    # early errors happen before any worker exists, so nothing needed tearing
    # down; "clean" would be a claim about something that never ran.
    "teardown": "n/a: no worker was started",
}
print(json.dumps(out))
PY
}
fail() { emit false "${2:-2}" "$1" "" 0 "$MODEL" "$EFFORT" "$SANDBOX" 0 ""; exit "${2:-2}"; }

TASK=""; MODEL=""; EFFORT=""; SANDBOX="read-only"; TIMEOUT=900

# Every value-taking option checks that a value actually follows. `shift 2` with
# only one argument left fails silently under `set -uo pipefail` without `-e`,
# leaving $1 unchanged — which spins this loop forever on a trailing `--task`.
# A value that was SUPPLIED but empty is a malformed request, not an omission:
# it usually means the caller's own extraction failed. Defaulting it would run a
# different configuration than the one that was asked for, silently.
need() {
  [ "$2" -ge 2 ] || fail "option $1 requires a value"
  [ -n "$3" ] || fail "option $1 was given an empty value"
}
while [ $# -gt 0 ]; do
  case "$1" in
    --task)    need "$1" $# "${2:-}"; TASK="$2";    shift 2 ;;
    --model)   need "$1" $# "${2:-}"; MODEL="$2";   shift 2 ;;
    --effort)  need "$1" $# "${2:-}"; EFFORT="$2";  shift 2 ;;
    --sandbox) need "$1" $# "${2:-}"; SANDBOX="$2"; shift 2 ;;
    --timeout) need "$1" $# "${2:-}"; TIMEOUT="$2"; shift 2 ;;
    # --keep was advertised but never forwarded to the supervisor; removed rather
    # than left as a flag that silently does nothing.
    *) fail "unknown argument: $1" ;;
  esac
done

# --- The real kill switch -------------------------------------------------
# `codex.enabled: false` must stop offloading everywhere, not only on the
# routing path: the gate can be bypassed by naming the relay agent directly, so
# enablement is enforced at the point of execution as well. Strictly boolean
# true, matching the gate — a string "false" is a config error, not consent.
python3 - "$POLICY" <<'PY' || fail "codex offload is disabled in policy.json (codex.enabled is not boolean true)"
import json, sys
try:
    cx = json.load(open(sys.argv[1])).get("codex") or {}
except Exception:
    sys.exit(1)
sys.exit(0 if cx.get("enabled") is True else 1)
PY

[ -n "$TASK" ] || fail "no --task file given"
[ -f "$TASK" ] || fail "task file does not exist: $TASK"
[ -s "$TASK" ] || fail "task file is empty: $TASK"

command -v codex >/dev/null 2>&1 || fail "codex CLI not found on PATH"

case "$SANDBOX" in
  read-only|workspace-write) ;;
  # The task text is attacker-influenced in the general case, so the sandbox mode
  # is not something prose in a prompt gets to widen.
  *) fail "unsupported sandbox mode: $SANDBOX (allowed: read-only, workspace-write)" ;;
esac

# A non-numeric timeout used to be word-split into the command position, making
# an arbitrary executable the thing `timeout` ran. Digits only, bounded.
case "$TIMEOUT" in
  ''|*[!0-9]*) fail "timeout must be a positive whole number of seconds: $TIMEOUT" ;;
esac
[ "$TIMEOUT" -ge 1 ] && [ "$TIMEOUT" -le 7200 ] || fail "timeout out of range (1-7200): $TIMEOUT"

# --- Validate model and effort against the policy -------------------------
# An unknown EXPLICIT value is rejected, not silently swapped: substituting a
# different model behind the caller's back makes the gate's recorded routing
# disagree with what actually ran. Only an OMITTED value is defaulted.
VALIDATED="$(python3 - "$POLICY" "$MODEL" "$EFFORT" <<'PY'
import json, sys
policy, model, effort = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    cx = json.load(open(policy)).get("codex") or {}
except Exception:
    print("ERR|policy.json could not be read"); raise SystemExit
by = cx.get("byTier") or {}
efforts = {"low", "medium", "high", "xhigh", "max"}
models = {v.get("model") for v in by.values()
          if isinstance(v, dict) and isinstance(v.get("model"), str)}
default = by.get("sonnet") if isinstance(by.get("sonnet"), dict) else {}

if not models:
    print("ERR|policy codex.byTier names no valid models"); raise SystemExit
if model and model not in models:
    print(f"ERR|unknown model '{model}'; policy allows: {', '.join(sorted(models))}"); raise SystemExit
if effort and effort not in efforts:
    print(f"ERR|unknown effort '{effort}'; allowed: {', '.join(sorted(efforts))}"); raise SystemExit

# Defaults come from config, so validate them too rather than trusting them.
model = model or default.get("model")
effort = effort or default.get("effort")
if model not in models:
    print("ERR|no model given and codex.byTier.sonnet.model is not valid"); raise SystemExit
if effort not in efforts:
    print("ERR|no effort given and codex.byTier.sonnet.effort is not valid"); raise SystemExit
print(f"OK|{model}|{effort}")
PY
)"
case "$VALIDATED" in
  OK\|*) MODEL="$(printf '%s' "$VALIDATED" | cut -d'|' -f2)"
         EFFORT="$(printf '%s' "$VALIDATED" | cut -d'|' -f3)" ;;
  *)     fail "$(printf '%s' "$VALIDATED" | cut -d'|' -f2-)" ;;
esac

OUTDIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-relay.XXXXXX")" || fail "could not create temp dir"
OUT="$OUTDIR/last-message.md"
ERR="$OUTDIR/stderr.log"

# --- Hand off to the single supervisor -----------------------------------
# `exec` deliberately: the supervisor becomes THIS process, so there is one
# owner of the worker, one signal handler and one JSON emission. The previous
# split between a bash trap and a python watchdog produced an orphaned worker on
# a signal in the launch gap, and two JSON objects when two signals arrived
# close together. Neither state is representable now.
exec python3 "$ROOT/bin/codex-supervise.py" \
  "$TIMEOUT" "$OUT" "$ERR" "$OUTDIR/stdout.log" "$TASK" \
  "$SANDBOX" "$MODEL" "$EFFORT" "$(pwd)"
exit 0
