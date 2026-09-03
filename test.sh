#!/usr/bin/env bash
# Test harness for the model-policy gate. Feeds recorded PreToolUse payloads on
# stdin and asserts the resolved model. Runs against a throwaway ledger.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$DIR/hooks/gate.mjs"
RUN="$DIR/hooks/run.sh"
PASS=0; FAIL=0

# node is not on PATH in a non-interactive shell when it is nvm-managed, which is
# the normal case over ssh. Without this the harness silently produces empty
# output and every NOOP-expecting assertion passes for the wrong reason.
find_node() {
  if command -v node >/dev/null 2>&1; then command -v node; return 0; fi
  for c in /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node /snap/bin/node; do
    [ -x "$c" ] && { echo "$c"; return 0; }
  done
  nvm_node=""
  for c in "$HOME"/.nvm/versions/node/*/bin/node; do
    [ -x "$c" ] && nvm_node="$c"
  done
  [ -n "$nvm_node" ] && { echo "$nvm_node"; return 0; }
  return 1
}
NODE="$(find_node)" || { echo "FATAL: no node found — cannot run tests"; exit 2; }
echo "node: $NODE"
echo

# Isolate test writes from the real ledger/sessions. This was previously only a
# comment: the suite wrote to, and then deleted, the production ledger. The real
# ledger is the sole record of how past spawns were routed and what they cost.
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/model-policy-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
export MODEL_POLICY_LEDGER="$SANDBOX/ledger.jsonl"
export MODEL_POLICY_SESSIONS="$SANDBOX/sessions"
# $DIR stays the repo (policy.json, hooks); $SESS/$LEDG are the sandbox.
SESS="$SANDBOX/sessions"
LEDG="$SANDBOX/ledger.jsonl"
SESSION_OK="test-session-sonnet"       # sonnet session, agents loaded at start
SESSION_READY="test-session-ready"     # opus session, agents loaded at start
SESSION_LEGACY="test-session-legacy"   # opus session recovered from transcript
mkdir -p "$SESS"
printf '{"model":"sonnet","via":"sessionstart","agents":["scout","worker"]}' > "$SESS/$SESSION_OK.json"
printf '{"model":"opus","via":"sessionstart","agents":["scout","worker"]}'   > "$SESS/$SESSION_READY.json"
printf '{"model":"opus","via":"transcript"}'                                 > "$SESS/$SESSION_LEGACY.json"

# check <name> <expected-model|DENY|NOOP> <json-payload>
check() {
  local name="$1" expect="$2" payload="$3" out got
  # Invoke through the production launcher, so the test exercises the same path
  # Claude Code uses rather than a bare `node` that only works when PATH is right.
  out="$(printf '%s' "$payload" | sh "$RUN" "$GATE" 2>/dev/null)"

  if [ "$expect" = "NOOP" ]; then
    if [ -z "$out" ]; then got="NOOP"; else got="output:$out"; fi
  elif [ "$expect" = "DENY" ]; then
    if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then got="DENY"; else got="${out:-NOOP}"; fi
  else
    got="$(printf '%s' "$out" | "$NODE" -e '
      let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
        try{process.stdout.write(JSON.parse(s).hookSpecificOutput.updatedInput.model)}catch{process.stdout.write("NOOP")}
      })')"
  fi

  if [ "$got" = "$expect" ]; then
    printf '  \033[32mPASS\033[0m  %-46s -> %s\n' "$name" "$got"; PASS=$((PASS+1))
  else
    printf '  \033[31mFAIL\033[0m  %-46s -> %s (expected %s)\n' "$name" "$got" "$expect"; FAIL=$((FAIL+1))
  fi
}

agent() { # <session_id> <inner-json>
  printf '{"session_id":"%s","tool_use_id":"t1","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{%s}}' "$1" "$2"
}
wf() { # <script>
  "$NODE" -e 'process.stdout.write(JSON.stringify({session_id:"s",tool_use_id:"t",hook_event_name:"PreToolUse",tool_name:"Workflow",tool_input:{script:process.argv[1]}}))' "$1"
}

echo "== Layer 1: agent type table =="
check "Explore"                 haiku  "$(agent no-session '"subagent_type":"Explore","description":"find x","prompt":"find the auth config"')"
check "statusline-setup"        haiku  "$(agent no-session '"subagent_type":"statusline-setup","description":"cfg","prompt":"set the statusline"')"
check "claude-code-guide"       sonnet "$(agent no-session '"subagent_type":"claude-code-guide","description":"q","prompt":"how do hooks work"')"
check "Plan"                    opus   "$(agent no-session '"subagent_type":"Plan","description":"plan","prompt":"plan the refactor"')"

echo
echo "== Layer 2: catch-all prompt scoring =="
check "mechanical + short -> haiku"    haiku  "$(agent no-session '"subagent_type":"general-purpose","description":"find","prompt":"find which file defines the auth config"')"
check "expensive verb -> opus"         opus   "$(agent no-session '"subagent_type":"general-purpose","description":"dbg","prompt":"debug why the login test is failing"')"
check "neither -> sonnet base"         sonnet "$(agent no-session '"subagent_type":"general-purpose","description":"sum","prompt":"summarise the changes in the release notes for me please"')"
check "mechanical but long -> sonnet"  sonnet "$(agent no-session '"subagent_type":"general-purpose","description":"find","prompt":"find the config. '"$(head -c 320 < /dev/zero | tr '\0' 'x')"'"')"
check "unknown type -> scored"         haiku  "$(agent no-session '"subagent_type":"some-custom-agent","description":"d","prompt":"list the open ports"')"

echo
echo "== Layer 3: clamps and tags =="
# Explicitly-requested cheaper model must never be upgraded. Observable result is
# NOOP: no rewrite emitted, so the requested haiku stands instead of Plan's opus.
check "requested cheaper is left alone" NOOP  "$(agent no-session '"subagent_type":"Plan","description":"p","prompt":"plan it","model":"haiku"')"
check "requested pricier is clamped"   haiku  "$(agent no-session '"subagent_type":"Explore","description":"e","prompt":"find it","model":"opus"')"
check "session sonnet clamps opus"     sonnet "$(agent $SESSION_OK '"subagent_type":"Plan","description":"p","prompt":"plan the migration"')"
check "session clamp never raises"     haiku  "$(agent $SESSION_OK '"subagent_type":"Explore","description":"e","prompt":"find it"')"
check "[hard] tag -> fable"            fable  "$(agent $SESSION_OK '"subagent_type":"Explore","description":"[hard] deep audit","prompt":"find it"')"
check "[cheap] tag -> haiku"           haiku  "$(agent no-session '"subagent_type":"Plan","description":"[cheap] quick look","prompt":"debug why this fails"')"
check "already correct -> no rewrite"  NOOP   "$(agent no-session '"subagent_type":"Explore","description":"e","prompt":"find it","model":"haiku"')"

echo
echo "== Layer 3d: an agent's own declared model is a ceiling =="
# Regression: 108 of 112 real spawns were `worker` (declared sonnet) and prompt
# scoring promoted every one to opus, inverting the purpose of the tier.
LONGVERB="implement and debug the root cause of this broken design. $(head -c 7000 < /dev/zero | tr '\0' 'x')"
check "worker is not promoted above sonnet" sonnet "$(agent no-session '"subagent_type":"worker","description":"impl","prompt":"'"$LONGVERB"'"')"
check "scout is not promoted above haiku"   haiku  "$(agent no-session '"subagent_type":"scout","description":"impl","prompt":"'"$LONGVERB"'"')"
check "undeclared type still scores freely" opus   "$(agent no-session '"subagent_type":"general-purpose","description":"impl","prompt":"'"$LONGVERB"'"')"
check "[hard] still overrides a ceiling"    fable  "$(agent no-session '"subagent_type":"worker","description":"[hard] go","prompt":"implement it"')"
# Length alone must not promote: real prompts have a median of 2692 chars, so a
# low minChars made "long" a constant rather than a signal.
check "2.7k chars, no verb -> base"         sonnet "$(agent no-session '"subagent_type":"general-purpose","description":"rev","prompt":"review task 1.1 '"$(head -c 2700 < /dev/zero | tr '\0' 'x')"'"')"

echo
echo "== Effort tiering: redirect to agent definitions =="
# redirect() extracts the resolved subagent_type instead of the model.
redirect() {
  local name="$1" expect="$2" payload="$3" got
  got="$(printf '%s' "$payload" | sh "$RUN" "$GATE" 2>/dev/null | "$NODE" -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      try{process.stdout.write(JSON.parse(s).hookSpecificOutput.updatedInput.subagent_type||"(empty)")}catch{process.stdout.write("NOOP")}})')"
  if [ "$got" = "$expect" ]; then
    printf '  \033[32mPASS\033[0m  %-46s -> %s\n' "$name" "$got"; PASS=$((PASS+1))
  else
    printf '  \033[31mFAIL\033[0m  %-46s -> %s (expected %s)\n' "$name" "$got" "$expect"; FAIL=$((FAIL+1))
  fi
}
redirect "general-purpose mechanical -> scout" scout   "$(agent $SESSION_READY '"subagent_type":"general-purpose","description":"d","prompt":"find which file defines the auth config"')"
redirect "unset type mechanical -> scout"      scout   "$(agent $SESSION_READY '"subagent_type":"","description":"d","prompt":"list the open ports"')"
redirect "sonnet tier not redirected by default" general-purpose "$(agent $SESSION_READY '"subagent_type":"general-purpose","description":"d","prompt":"summarise the release notes for me please"')"
# Explore is a tuned built-in: model gets set, but the type must NOT be swapped.
redirect "Explore keeps its own prompt"        Explore "$(agent $SESSION_READY '"subagent_type":"Explore","description":"d","prompt":"find the auth config"')"
check    "Explore still routed to haiku"       haiku   "$(agent $SESSION_READY '"subagent_type":"Explore","description":"d","prompt":"find the auth config"')"

# The guard. Agent definitions do not hot-reload, so redirecting in a session that
# never loaded them fails the spawn with "Agent type not found". Both of these
# must fall back to model-only routing.
redirect "transcript-recovered session: NO redirect" general-purpose "$(agent $SESSION_LEGACY '"subagent_type":"general-purpose","description":"d","prompt":"find which file defines the auth config"')"
redirect "unknown session: NO redirect"              general-purpose "$(agent no-session '"subagent_type":"general-purpose","description":"d","prompt":"find which file defines the auth config"')"
check    "...but model routing still applies"        haiku           "$(agent no-session '"subagent_type":"general-purpose","description":"d","prompt":"find which file defines the auth config"')"

echo
echo "== Workflow gate =="
check "8 agents, no models -> deny"    DENY "$(wf 'const a=await agent("x");agent("b");agent("c");agent("d");agent("e");agent("f");agent("g");agent("h");')"
check "2 agents, no models -> allow"   NOOP "$(wf 'agent("x");agent("y");')"
check "8 agents, models set -> allow"  NOOP "$(wf 'agent("a",{model:"haiku"});agent("b");agent("c");agent("d");agent("e");agent("f");agent("g");agent("h");')"
check "no script field -> allow"       NOOP '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Workflow","tool_input":{"name":"saved-wf"}}'
# The idiomatic fan-out: one literal agent( call that spawns N. Counting literal
# occurrences alone would let this straight through.
check "parallel+map fan-out, no models -> deny"  DENY "$(wf 'const r = await parallel(FILES.map(f => () => agent("audit " + f)));')"
check "pipeline fan-out, no models -> deny"      DENY "$(wf 'const r = await pipeline(ITEMS, i => agent("stage one " + i), x => agent("stage two"));')"
check "parallel fan-out WITH models -> allow"    NOOP "$(wf 'const r = await parallel(FILES.map(f => () => agent("audit " + f, {model: "haiku"})));')"
check "parallel without any agent -> allow"      NOOP "$(wf 'const r = await parallel(items.map(i => () => somethingElse(i)));')"
# False-positive guards. Prose is not code: matching the raw script text denies
# scripts that are fine, which is worse than missing an optimisation.
check "'parallel' in a COMMENT -> allow"         NOOP "$(wf '// fan these out in parallel (one per file)
const r = await agent("summarise the release notes");')"
check "'parallel' in a PROMPT string -> allow"   NOOP "$(wf 'const r = await agent("run the checks in parallel (fast path)");')"
check "'pipeline' in a prompt -> allow"          NOOP "$(wf 'const r = await agent("describe the build pipeline (CI)");')"
# Conversely, a model: mentioned only inside a string is not real tier coverage.
check "model: only inside a string -> still deny" DENY "$(wf 'const r = await parallel(F.map(f => () => agent("set model: haiku please")));')"

echo
echo "== Workflow enforcement: script rewriting =="
# Scripts above carry no `export const meta`, so the rewriter refuses them and the
# deny fallback stands. A real script has meta and gets tiered instead of refused.
META='export const meta = { name: "t", description: "d", phases: [{ title: "P" }] }'
# wfe <name> <expected> <script> -- expected: ENFORCED | NOOP | DENY
wfe() {
  local name="$1" expect="$2" out got
  out="$(printf '%s' "$(wf "$3")" | sh "$RUN" "$GATE" 2>/dev/null)"
  if printf '%s' "$out" | grep -q '__mpAgent'; then got="ENFORCED"
  elif printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then got="DENY"
  elif [ -z "$out" ]; then got="NOOP"; else got="OTHER"; fi
  if [ "$got" = "$expect" ]; then
    printf '  \033[32mPASS\033[0m  %-46s -> %s\n' "$name" "$got"; PASS=$((PASS+1))
  else
    printf '  \033[31mFAIL\033[0m  %-46s -> %s (expected %s)\n' "$name" "$got" "$expect"; FAIL=$((FAIL+1))
  fi
}
wfe "wide fan-out is tiered, not denied"  ENFORCED "$META
const r = await parallel(FILES.map(f => () => agent(\"audit \" + f)));"
wfe "single agent() is tiered too"        ENFORCED "$META
const r = await agent(\"summarise the notes\");"
wfe "already-tiered script still wrapped" ENFORCED "$META
const r = await agent(\"x\", { model: \"haiku\" });"
wfe "no meta -> falls back to deny"       DENY     "const r = await parallel(F.map(f => () => agent(\"audit \" + f)));"
wfe "no agent() calls -> untouched"       NOOP     "$META
const r = await parallel(items.map(i => () => other(i)));"

# The rewrite must never disturb text that only looks like a call site.
REWRITTEN="$(printf '%s' "$(wf "$META
// fan out in parallel: agent( here is a comment
const note = \"call agent(x) in a string\";
const o = { agent: 1 }; const z = o.agent;
const r = await agent(\"go\");")" | sh "$RUN" "$GATE" 2>/dev/null)"
assert_has() { # <name> <needle> <haystack>
  case "$3" in
    *"$2"*) printf '  \033[32mPASS\033[0m  %-46s -> intact\n' "$1"; PASS=$((PASS+1));;
    *) printf '  \033[31mFAIL\033[0m  %-46s -> MODIFIED\n' "$1"; FAIL=$((FAIL+1));;
  esac
}
assert_has "comment text left alone"      'agent( here is a comment' "$REWRITTEN"
assert_has "string literal left alone"    'call agent(x) in a string' "$REWRITTEN"
assert_has "property access left alone"   'o.agent'                   "$REWRITTEN"

echo
echo "== Workflow enforcement: indirect {scriptPath} / {name} =="
# These hand over a reference, not source. The file is read back and rewritten in
# memory; it must never be modified on disk.
WFFILE="$SANDBOX/hand-written.js"
printf '%s\nconst r = await parallel(F.map(f => () => agent("audit " + f)));\n' "$META" > "$WFFILE"
WFSUM_BEFORE="$(cksum < "$WFFILE")"
sp() { # <extra-json>
  "$NODE" -e 'process.stdout.write(JSON.stringify({session_id:"s",tool_use_id:"t",hook_event_name:"PreToolUse",tool_name:"Workflow",tool_input:Object.assign({scriptPath:process.argv[1]},JSON.parse(process.argv[2]||"{}"))}))' "$WFFILE" "${1:-}"
}
spout="$(printf '%s' "$(sp)" | sh "$RUN" "$GATE" 2>/dev/null)"
case "$spout" in
  *__mpAgent*) printf '  \033[32mPASS\033[0m  %-46s -> ENFORCED\n' "scriptPath is read back and tiered"; PASS=$((PASS+1));;
  *) printf '  \033[31mFAIL\033[0m  %-46s -> %s\n' "scriptPath is read back and tiered" "${spout:-NOOP}"; FAIL=$((FAIL+1));;
esac
# scriptPath takes precedence over script, so it must be dropped or the rewrite is inert.
case "$spout" in
  *'"scriptPath"'*) printf '  \033[31mFAIL\033[0m  %-46s -> STILL PRESENT\n' "scriptPath dropped from updatedInput"; FAIL=$((FAIL+1));;
  *) printf '  \033[32mPASS\033[0m  %-46s -> dropped\n' "scriptPath dropped from updatedInput"; PASS=$((PASS+1));;
esac
if [ "$WFSUM_BEFORE" = "$(cksum < "$WFFILE")" ]; then
  printf '  \033[32mPASS\033[0m  %-46s -> unmodified\n' "the file on disk is NOT modified"; PASS=$((PASS+1))
else
  printf '  \033[31mFAIL\033[0m  %-46s -> MODIFIED ON DISK\n' "the file on disk is NOT modified"; FAIL=$((FAIL+1))
fi

# Resuming replays agents whose (prompt, opts) match. Injecting a model changes
# opts and throws the cache away, so resume must be left alone.
check "resume is not re-tiered"        NOOP "$(sp '{"resumeFromRunId":"wf_abc123"}')"

# A persisted inline script already carries the shim; re-injecting would nest it.
printf '%s\nconst __mpAgent = 1;\nconst r = await agent("x");\n' "$META" > "$SANDBOX/already.js"
check "already-shimmed file left alone" NOOP "$("$NODE" -e 'process.stdout.write(JSON.stringify({session_id:"s",tool_use_id:"t",hook_event_name:"PreToolUse",tool_name:"Workflow",tool_input:{scriptPath:process.argv[1]}}))' "$SANDBOX/already.js")"
check "unreadable scriptPath -> allow"  NOOP "$("$NODE" -e 'process.stdout.write(JSON.stringify({session_id:"s",tool_use_id:"t",hook_event_name:"PreToolUse",tool_name:"Workflow",tool_input:{scriptPath:"/nonexistent/nope.js"}}))')"
check "built-in {name} -> allow"        NOOP '{"session_id":"s","tool_use_id":"t","hook_event_name":"PreToolUse","tool_name":"Workflow","tool_input":{"name":"some-builtin"}}'
check "traversal in {name} -> allow"    NOOP '{"session_id":"s","tool_use_id":"t","hook_event_name":"PreToolUse","tool_name":"Workflow","tool_input":{"name":"../../../etc/passwd"}}'

# Nested workflow(): the child script is never seen by the gate, and patching
# globalThis.agent was measured NOT to reach it (child ran opus, parent haiku on
# equivalent prompts). So workflow() must NOT be rewritten, only reported.
NESTED="$(printf '%s' "$(wf "$META
const mine = await agent(\"go\");
const theirs = await workflow({ scriptPath: \"/tmp/child.js\" });")" | sh "$RUN" "$GATE" 2>/dev/null)"
case "$NESTED" in
  *__mpWorkflow*) printf '  \033[31mFAIL\033[0m  %-46s -> REWROTE (does not work)\n' "workflow() is not rewritten"; FAIL=$((FAIL+1));;
  *) printf '  \033[32mPASS\033[0m  %-46s -> left alone\n' "workflow() is not rewritten"; PASS=$((PASS+1));;
esac
case "$NESTED" in
  *"nested workflow"*) printf '  \033[32mPASS\033[0m  %-46s -> warned\n' "nested workflow() is reported to Claude"; PASS=$((PASS+1));;
  *) printf '  \033[31mFAIL\033[0m  %-46s -> SILENT\n' "nested workflow() is reported to Claude"; FAIL=$((FAIL+1));;
esac
case "$NESTED" in
  *__mpAgent*) printf '  \033[32mPASS\033[0m  %-46s -> still tiered\n' "the parent's own agent() is still tiered"; PASS=$((PASS+1));;
  *) printf '  \033[31mFAIL\033[0m  %-46s -> NOT TIERED\n' "the parent's own agent() is still tiered"; FAIL=$((FAIL+1));;
esac

echo
echo "== Fail-open =="
check "unrelated tool ignored"         NOOP '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
check "malformed stdin"                NOOP 'not json at all'
check "empty stdin"                    NOOP ''
check "missing tool_input"             NOOP '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Agent"}'

cp "$DIR/policy.json" "$DIR/policy.json.testbak"
printf '{ broken' > "$DIR/policy.json"
check "corrupt policy.json"            NOOP "$(agent no-session '"subagent_type":"Explore","description":"e","prompt":"find it"')"
mv "$DIR/policy.json.testbak" "$DIR/policy.json"

echo
echo "== Regression guards =="

assert() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf '  \033[32mPASS\033[0m  %-46s -> %s\n' "$1" "$3"; PASS=$((PASS+1))
  else
    printf '  \033[31mFAIL\033[0m  %-46s -> %s (expected %s)\n' "$1" "$3" "$2"; FAIL=$((FAIL+1))
  fi
}

# A typo in policy.json must never be written into `model` — that would fail the
# spawn, which is the opposite of failing open.
cp "$DIR/policy.json" "$DIR/policy.json.tierbak"
"$NODE" -e 'const fs=require("fs"),f=process.argv[1];const j=JSON.parse(fs.readFileSync(f,"utf8"));j.agentTypes.Explore="haku";fs.writeFileSync(f,JSON.stringify(j));' "$DIR/policy.json"
check "invalid tier in policy -> no rewrite" NOOP "$(agent no-session '"subagent_type":"Explore","description":"e","prompt":"find it"')"
mv "$DIR/policy.json.tierbak" "$DIR/policy.json"

# SessionStart's `model` field is not guaranteed present. Recovering the model
# from the transcript must NOT discard the agents list recorded at session start,
# or effort tiering silently stops for the rest of that session.
FAKE_TS="$SESS/.fake-transcript.jsonl"
printf '{"type":"assistant","message":{"model":"claude-opus-5","usage":{"output_tokens":1}}}\n' > "$FAKE_TS"
S_NULL="test-session-nullmodel"
printf '{"model":null,"via":"sessionstart","agents":["scout","worker"]}' > "$SESS/$S_NULL.json"
NULL_PAYLOAD="$(printf '{"session_id":"%s","transcript_path":"%s","tool_use_id":"t","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","description":"d","prompt":"find which file defines the auth config"}}' "$S_NULL" "$FAKE_TS")"
redirect "null session model -> redirect survives" scout "$NULL_PAYLOAD"
assert   "...and provenance is preserved" "sessionstart" \
  "$("$NODE" -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).via)' "$SESS/$S_NULL.json" 2>/dev/null)"
assert   "...and the recovered model is stored" "opus" \
  "$("$NODE" -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).model)' "$SESS/$S_NULL.json" 2>/dev/null)"

# route and complete must share a join key, or the tuner pairs rows by arrival
# order and mismatches every parallel fan-out.
rm -f "$LEDG"
printf '%s' "$(agent no-session '"subagent_type":"Explore","description":"e","prompt":"  FIND   the Auth Config  "')" | sh "$RUN" "$GATE" >/dev/null 2>&1
assert "route row carries a prompt fingerprint" "find the auth config" \
  "$(grep '"event":"route"' "$LEDG" 2>/dev/null | tail -1 | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).prompt_fp)}catch{console.log("MISSING")}})')"

rm -f "$FAKE_TS" "$SESS/$S_NULL.json"

# A mid-session /model change does not fire SessionStart. Once the record ages
# out, the transcript must win — otherwise the clamp measures against the model
# the session started on and can route ABOVE the session's current tier.
STALE_TS="$SESS/.stale-transcript.jsonl"
printf '{"type":"assistant","message":{"model":"claude-sonnet-5","usage":{"output_tokens":1}}}\n' > "$STALE_TS"
S_STALE="test-session-stale"
printf '{"model":"opus","at":"2020-01-01T00:00:00.000Z","via":"sessionstart","agents":["scout","worker"]}' > "$SESS/$S_STALE.json"
check "stale record -> transcript wins (clamps down)" sonnet \
  "$(printf '{"session_id":"%s","transcript_path":"%s","tool_use_id":"t","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"Plan","description":"p","prompt":"plan the migration"}}' "$S_STALE" "$STALE_TS")"
# A fresh record must NOT trigger a transcript re-read.
printf '{"model":"opus","at":"%s","via":"sessionstart","agents":["scout","worker"]}' "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" > "$SESS/$S_STALE.json"
check "fresh record -> cached tier is trusted"        opus \
  "$(printf '{"session_id":"%s","transcript_path":"%s","tool_use_id":"t","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"Plan","description":"p","prompt":"plan the migration"}}' "$S_STALE" "$STALE_TS")"
rm -f "$STALE_TS" "$SESS/$S_STALE.json"

echo
echo "== Join key: fan-out collisions and SubagentStop provenance =="

LOG="$DIR/hooks/log.mjs"

# Read one field off the last ledger row of a given event type.
ledger_field() { # <event> <field>
  grep "\"event\":\"$1\"" "$LEDG" 2>/dev/null | tail -1 \
    | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const v=JSON.parse(s)[process.argv[1]];console.log(v===undefined?"MISSING":String(v))}catch{console.log("MISSING")}})' "$2"
}

# These two differ only past character 100 — exactly the shape of a fan-out, where
# every agent shares a preamble and differs in the task number. The fingerprint
# cannot separate them; the hash must, or the tuner pairs the wrong route row with
# the wrong outcome.
FAN_A='you are the task reviewer for one task of a plan. working dir is the repo root and the branch is ready. task 7 alpha'
FAN_B='you are the task reviewer for one task of a plan. working dir is the repo root and the branch is ready. task 9 beta'
S_JOIN="test-session-join"
printf '{"model":"opus","via":"sessionstart","agents":["scout","worker"]}' > "$SESS/$S_JOIN.json"

rm -f "$LEDG"
printf '%s' "$(agent "$S_JOIN" "\"subagent_type\":\"general-purpose\",\"description\":\"d\",\"prompt\":\"$FAN_A\"")" | sh "$RUN" "$GATE" >/dev/null 2>&1
FP_A="$(ledger_field route prompt_fp)"; SHA_A="$(ledger_field route prompt_sha)"
printf '%s' "$(agent "$S_JOIN" "\"subagent_type\":\"general-purpose\",\"description\":\"d\",\"prompt\":\"$FAN_B\"")" | sh "$RUN" "$GATE" >/dev/null 2>&1
FP_B="$(ledger_field route prompt_fp)"; SHA_B="$(ledger_field route prompt_sha)"

assert "route row carries a prompt hash"           "16"   "$(printf '%s' "$SHA_A" | wc -c | tr -d ' ')"
assert "fan-out siblings share a fingerprint"      "same" "$([ "$FP_A" = "$FP_B" ] && echo same || echo differ)"
assert "...but the hash separates them"            "differ" "$([ "$SHA_A" = "$SHA_B" ] && echo same || echo differ)"
# The sidecar is keyed on the FINGERPRINT, not the hash, so a fan-out writes one
# identical line per sibling. That is deliberate: `routed` only ever asks "did the
# gate see a spawn with this prompt", and a shared line answers that for all of
# them. Pairing an individual spawn is the hash's job, not the sidecar's.
assert "gate records every spawn in the sidecar"   "2" \
  "$(grep -c "^g $FP_B\$" "$SESS/$S_JOIN.events" 2>/dev/null || echo 0)"

# SubagentStop side. A transcript the log hook can actually read: one user turn
# carrying the prompt, one assistant turn carrying model and usage.
AGENT_TS="$SANDBOX/agent-transcript.jsonl"
{ printf '{"type":"user","message":{"content":"%s"}}\n' "$FAN_B"
  printf '{"type":"assistant","message":{"model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":20}}}\n'; } > "$AGENT_TS"
stop() { # <agent_id>
  printf '{"session_id":"%s","hook_event_name":"SubagentStop","agent_id":"%s","agent_type":"general-purpose","prompt_id":"p1","agent_transcript_path":"%s","last_assistant_message":"done"}' \
    "$S_JOIN" "$1" "$AGENT_TS"
}

printf '%s' "$(stop ag1)" | sh "$RUN" "$LOG" >/dev/null 2>&1
assert "complete row joins the route row by hash"  "$SHA_B" "$(ledger_field complete prompt_sha)"
assert "gated spawn is marked routed"              "true"   "$(ledger_field complete routed)"
assert "first stop is seq 1"                       "1"      "$(ledger_field complete stop_seq)"
assert "native prompt_id is carried through"       "p1"     "$(ledger_field complete prompt_id)"

# The same agent stopping again supersedes rather than adds: usage is re-read
# cumulatively, so a consumer must be able to keep only the highest seq.
printf '%s' "$(stop ag1)" | sh "$RUN" "$LOG" >/dev/null 2>&1
assert "repeat stop for one agent increments seq"  "2"      "$(ledger_field complete stop_seq)"
printf '%s' "$(stop ag2)" | sh "$RUN" "$LOG" >/dev/null 2>&1
assert "a different agent starts its own seq"      "1"      "$(ledger_field complete stop_seq)"

# An agent the gate never saw (a Workflow agent() that borrowed an agentType)
# must not be reported as having escaped the gate.
UNGATED_TS="$SANDBOX/ungated-transcript.jsonl"
{ printf '{"type":"user","message":{"content":"a prompt that never passed the gate"}}\n'
  printf '{"type":"assistant","message":{"model":"claude-haiku-4-5-20251001","usage":{"input_tokens":1,"output_tokens":2}}}\n'; } > "$UNGATED_TS"
printf '{"session_id":"%s","hook_event_name":"SubagentStop","agent_id":"ag3","agent_type":"general-purpose","agent_transcript_path":"%s","last_assistant_message":"done"}' \
  "$S_JOIN" "$UNGATED_TS" | sh "$RUN" "$LOG" >/dev/null 2>&1
assert "ungated spawn is marked not routed"        "false"  "$(ledger_field complete routed)"

# Fail-open: the log hook must stay silent on rubbish.
assert "log hook: malformed stdin -> no output"    ""       "$(printf 'not json' | sh "$RUN" "$LOG" 2>&1)"
assert "log hook: empty stdin -> no output"        ""       "$(printf '' | sh "$RUN" "$LOG" 2>&1)"

rm -f "$AGENT_TS" "$UNGATED_TS" "$SESS/$S_JOIN.json" "$SESS/$S_JOIN.events"

rm -f "$SESS/$SESSION_OK.json" "$SESS/$SESSION_READY.json" "$SESS/$SESSION_LEGACY.json"
echo
echo "-----------------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
