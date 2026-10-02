#!/usr/bin/env bash
# Is the model policy actually being enforced?
#
# Answers three questions from evidence, not from configuration:
#   1. Are the hooks firing at all?
#   2. What tier did the policy CHOOSE for each spawn?
#   3. What model did the agent ACTUALLY run on?
#
# (3) is the one that matters. A route entry only records what the hook asked
# for; `updatedInput` was once silently ignored, and the ledger looked perfect
# while every agent ran on opus.
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"

NODE=""
for c in node /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node /snap/bin/node; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -e '' >/dev/null 2>&1; then NODE="$c"; break; fi
done
if [ -z "$NODE" ]; then
  for c in "$HOME"/.nvm/versions/node/*/bin/node; do
    [ -x "$c" ] && { NODE="$c"; break; }
  done
fi
if [ -z "$NODE" ]; then
  # A missing Node launcher makes hooks fail open. When agy is otherwise live,
  # calling that a warning would falsely report an enabled offload as verified.
  AGY_READY="$(python3 - "$ROOT/policy.json" <<'PY' 2>/dev/null || true
import json,os,sys
try:
 a=json.load(open(sys.argv[1])).get('agy') or {}
 binary=str(a.get('binary') or '$HOME/.local/bin/agy').replace('$HOME',os.path.expanduser('~'))
 bwrap=str((a.get('sandbox') or {}).get('bwrap') or '/usr/bin/bwrap')
 print('yes' if a.get('enabled') is True and os.access(binary,os.X_OK) and os.access(bwrap,os.X_OK) else 'no')
except Exception: print('no')
PY
)"
  if [ "$AGY_READY" = yes ]; then
    echo "FAIL: Antigravity is enabled and available, but node is missing so its hook cannot run"
  else
    echo "no usable node found"
  fi
  exit 1
fi

# Antigravity deliberately has an absolute configured binary: /usr/local/bin/agy
# is an unrelated desktop launcher. Missing it is a capability warning, not a
# policy failure — native routing remains safe.
AGY_BIN="$("$NODE" -e 'try { const a=require(process.argv[1]).agy||{}; process.stdout.write(a.binary||"$HOME/.local/bin/agy"); } catch {}' "$ROOT/policy.json" 2>/dev/null)"
case "$AGY_BIN" in '$HOME'/*) AGY_BIN="$HOME/${AGY_BIN#\$HOME/}" ;; esac
if [ -n "$AGY_BIN" ] && [ ! -x "$AGY_BIN" ]; then
  echo "warning: Antigravity binary is not executable: $AGY_BIN"
fi

"$NODE" -e '
const fs = require("fs"), path = require("path");
const root = process.argv[1];
const days = Number(process.argv[2] || 7);
const since = Date.now() - days * 86400e3;

let rows = [];
try {
  rows = fs.readFileSync(path.join(root, "ledger.jsonl"), "utf8")
    .trim().split("\n").filter(Boolean)
    .map(l => { try { return JSON.parse(l); } catch { return null; } })
    .filter(Boolean)
    .filter(r => !/^(no-session|test-)/.test(String(r.session_id)))
    .filter(r => Date.parse(r.ts) >= since);
} catch { console.log("no ledger yet — the hooks have not logged anything"); process.exit(0); }

/**
 * SubagentStop fires more than once for a long-running agent, and each firing re-reads
 * the whole transcript — so the rows for one agent_id are cumulative snapshots that
 * supersede each other. Counting them all inflated every total here by 20% against a
 * real ledger. Keep the highest stop_seq per agent (turns, on rows written before
 * stop_seq existed).
 */
const seqOf = (r) => r.stop_seq ?? r.usage?.turns ?? 0;
const dedupe = (list) => {
  const best = new Map();
  const anonymous = [];
  for (const r of list) {
    if (!r.agent_id) { anonymous.push(r); continue; }
    const cur = best.get(r.agent_id);
    if (!cur || seqOf(r) >= seqOf(cur)) best.set(r.agent_id, r);
  }
  return [...best.values(), ...anonymous];
};

const routes    = rows.filter(r => r.event === "route");
const doneRaw   = rows.filter(r => r.event === "complete");
const done      = dedupe(doneRaw);
const superseded = doneRaw.length - done.length;
const wf        = rows.filter(r => r.event === "workflow");
const errs      = rows.filter(r => r.event === "error");

const pad = (s, n) => String(s).padEnd(n);
const tbl = (title, pairs) => {
  if (!pairs.length) return;
  console.log("\n" + title);
  const w = Math.max(...pairs.map(p => String(p[0]).length));
  for (const [k, v] of pairs.sort((a, b) => b[1] - a[1])) console.log("   " + pad(k, w) + "  " + v);
};
const count = (arr, f) => Object.entries(arr.reduce((a, r) => {
  const k = String(f(r)); a[k] = (a[k] || 0) + 1; return a;
}, {}));

console.log(`last ${days}d: ${routes.length} Agent spawns routed, ${done.length} completed, ` +
            `${wf.length} workflows checked (${wf.filter(w => w.denied).length} denied)` +
            (superseded ? `, ${superseded} superseded rows folded` : "") +
            (errs.length ? `, ${errs.length} POLICY ERRORS` : ""));

if (!routes.length && !done.length) {
  console.log("\nnothing logged. Either no subagents ran, or the hooks are not registered.");
  console.log("check:  grep -l model-policy ~/.claude*/settings.json");
}

tbl("tier CHOSEN by the policy:", count(routes, r => r.set));
tbl("why:",                       count(routes, r => r.rule));
tbl("model ACTUALLY run (ground truth):", count(done.filter(r => r.actual_model), r => r.actual_model));

// Workflow enforcement: scripts rewritten vs scripts that escaped.
if (wf.length) {
  const ok   = wf.filter(w => w.enforced);
  const esc  = wf.filter(w => !w.enforced && !w.denied);
  const sites = ok.reduce((a, w) => a + (w.sites || 0), 0);
  console.log(`\nWorkflow enforcement: ${ok.length}/${wf.length} scripts rewritten ` +
              `(${sites} agent() call sites tiered)`);
  if (esc.length) {
    console.log(`   ${esc.length} not rewritten — these tier themselves or not at all:`);
    tbl("", count(esc, w => "   " + (w.reason || "unknown")));
  }
}

const unrouted = done.filter(r => r.agent_type === "workflow-subagent");
if (unrouted.length) {
  const spend = unrouted.reduce((a, r) => a + (r.usage?.output || 0), 0);
  console.log(`\n${unrouted.length} workflow subagents ran (${spend.toLocaleString()} output tokens).`);
  console.log("   These never reach the Agent gate, so there is no `route` row for them —");
  console.log("   the injected shim sets their model, and this is the only proof it worked:");
  tbl("   what they actually ran on:", count(unrouted.filter(r => r.actual_model), r => r.actual_model));
}

const failed = done.filter(r => r.looks_failed);
if (failed.length) console.log(`\n${failed.length} completion(s) look like the agent gave up — a downgrade may have backfired.`);
for (const e of errs) console.log("\nERROR: " + e.reason + " (tier=" + e.tier + ")");
' "$ROOT" "${1:-7}"
