#!/usr/bin/env bash
# Test harness for the model-policy gate. Feeds recorded PreToolUse payloads on
# stdin and asserts the resolved model. Runs against a throwaway ledger.
set -uo pipefail

# Undefined helpers otherwise return 127 but can be hidden inside a command
# substitution. Make that a loud, terminal harness failure.
command_not_found_handle() {
  printf 'FATAL: unknown test command: %s\n' "$1" >&2
  exit 127
}

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
export MODEL_POLICY_GRANTS="$SANDBOX/grants"
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

assert() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf '  \033[32mPASS\033[0m  %-46s -> %s\n' "$1" "$3"; PASS=$((PASS+1))
  else
    printf '  \033[31mFAIL\033[0m  %-46s -> %s (expected %s)\n' "$1" "$3" "$2"; FAIL=$((FAIL+1))
  fi
}

assert "assert helper precedes every use" yes \
  "$(awk '/^assert\(\)/ { defined=NR } /^[[:space:]]*assert / && !defined { bad=1 } END { print bad ? "no" : "yes" }' "$0")"
assert "unknown command handler is fatal" 127 \
  "$(bash -c 'command_not_found_handle() { exit 127; }; nonexistent_test_helper >/dev/null 2>&1; printf "%s" "$?"')"

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
check "[hard] tag -> opus"             opus   "$(agent $SESSION_OK '"subagent_type":"Explore","description":"[hard] deep audit","prompt":"find it"')"
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
check "[hard] still overrides a ceiling"    opus   "$(agent no-session '"subagent_type":"worker","description":"[hard] go","prompt":"implement it"')"
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
RELAY_GRANT=dddddddddddddddddddddddddddddddddddddddddddddddd
check "agy relay allows only exact grant command" NOOP "{\"session_id\":\"s\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"agent_type\":\"agy\",\"tool_input\":{\"command\":\"bash $DIR/bin/agy-relay.sh --grant $RELAY_GRANT\"}}"
check "agy relay denies chained Bash" DENY "{\"session_id\":\"s\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"agent_type\":\"agy\",\"tool_input\":{\"command\":\"bash $DIR/bin/agy-relay.sh --grant $RELAY_GRANT; id\"}}"
check "agy relay denies direct agy" DENY '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Bash","agent_type":"agy","tool_input":{"command":"agy --dangerously-skip-permissions"}}'
check "agy relay denies Write" DENY '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Write","agent_type":"agy","tool_input":{"file_path":"/tmp/x"}}'
check "agy relay denies Read" DENY '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Read","agent_type":"agy","tool_input":{"file_path":"/tmp/x"}}'
check "agy relay denies Glob" DENY '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Glob","agent_type":"agy","tool_input":{"pattern":"*"}}'
check "agy relay denies Grep" DENY '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Grep","agent_type":"agy","tool_input":{"pattern":"secret"}}'
check "main-thread Bash remains untouched" NOOP '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
check "a different agent's Bash remains untouched" NOOP '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Bash","agent_type":"worker","tool_input":{"command":"ls"}}'
relay_bash() { "$NODE" -e 'process.stdout.write(JSON.stringify({session_id:"s",hook_event_name:"PreToolUse",tool_name:"Bash",agent_type:"agy",tool_input:{command:process.argv[1]}}))' "$1"; }
for suffix in ' --extra' $'\necho escaped' ' $(id)' ' `id`' ' > /tmp/escaped'; do
  check "agy relay denies Bash suffix" DENY "$(relay_bash "bash $DIR/bin/agy-relay.sh --grant $RELAY_GRANT$suffix")"
done
check "agy relay denies Edit" DENY '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Edit","agent_type":"agy","tool_input":{"file_path":"/tmp/x"}}'
check "agy relay denies NotebookEdit" DENY '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"NotebookEdit","agent_type":"agy","tool_input":{"notebook_path":"/tmp/x"}}'
MERGE_FIXTURE="$SANDBOX/merge-fixture"; mkdir -p "$MERGE_FIXTURE"
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"custom-hook"},{"type":"command","command":"%s"}]}]}}\n' "$DIR/hooks/gate.mjs" > "$MERGE_FIXTURE/settings.json"
"$NODE" "$DIR/install-merge.mjs" "$MERGE_FIXTURE" "$DIR/hooks" >/dev/null
assert "installer isolates gate from a shared custom-hook group" yes \
  "$("$NODE" -e 'const s=require(process.argv[1]);const g=s.hooks.PreToolUse;const custom=g.find(x=>x.hooks.some(h=>h.command==="custom-hook"));const own=g.find(x=>x.hooks.some(h=>h.command.includes("gate.mjs")));process.stdout.write(custom?.matcher==="Bash"&&own!==custom&&own?.matcher==="Agent|Workflow|Bash"?"yes":"no")' "$MERGE_FIXTURE/settings.json")"
check "malformed stdin"                NOOP 'not json at all'
check "empty stdin"                    NOOP ''
check "missing tool_input"             NOOP '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Agent"}'

# Point the hooks at a broken policy in the sandbox rather than overwriting the
# real one. The previous version wrote `{ broken` to the live policy.json and
# moved it back afterwards; an interrupted run left routing silently disabled.
printf '{ broken' > "$SANDBOX/broken-policy.json"
check_env="MODEL_POLICY_POLICY=$SANDBOX/broken-policy.json"
got="$(printf '%s' "$(agent no-session '"subagent_type":"Explore","description":"e","prompt":"find it"')" \
  | env MODEL_POLICY_POLICY="$SANDBOX/broken-policy.json" sh "$RUN" "$GATE" 2>/dev/null)"
if [ -z "$got" ]; then
  printf '  \033[32mPASS\033[0m  %-46s -> %s\n' "corrupt policy.json" "NOOP"; PASS=$((PASS+1))
else
  printf '  \033[31mFAIL\033[0m  %-46s -> %s (expected NOOP)\n' "corrupt policy.json" "$got"; FAIL=$((FAIL+1))
fi
got="$(printf '%s' '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Bash","agent_type":"agy","tool_input":{"command":"id"}}' \
  | env MODEL_POLICY_POLICY="$SANDBOX/broken-policy.json" sh "$RUN" "$GATE" 2>/dev/null)"
assert "corrupt policy fails closed for fallback agy" yes "$(printf '%s' "$got" | grep -q 'permissionDecision":"deny' && echo yes || echo no)"
unset check_env

echo
echo "== Regression guards =="

# A typo in policy.json must never be written into `model` — that would fail the
# spawn, which is the opposite of failing open.
# Derived in the sandbox. This used to write the typo into the LIVE policy and
# move a backup over it afterwards: an interrupted or concurrent run left
# `agentTypes.Explore = "haku"` installed, silently breaking every Explore spawn.
"$NODE" -e 'const fs=require("fs");const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));j.agentTypes.Explore="haku";fs.writeFileSync(process.argv[2],JSON.stringify(j));' \
  "$DIR/policy.json" "$SANDBOX/bad-tier.json"
got="$(printf '%s' "$(agent no-session '"subagent_type":"Explore","description":"e","prompt":"find it"')" \
  | env MODEL_POLICY_POLICY="$SANDBOX/bad-tier.json" sh "$RUN" "$GATE" 2>/dev/null)"
if [ -z "$got" ]; then
  printf '  \033[32mPASS\033[0m  %-46s -> %s\n' "invalid tier in policy -> no rewrite" "NOOP"; PASS=$((PASS+1))
else
  printf '  \033[31mFAIL\033[0m  %-46s -> %s (expected NOOP)\n' "invalid tier in policy -> no rewrite" "$got"; FAIL=$((FAIL+1))
fi

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

echo
echo "== Codex offload: routing work to OpenAI models =="
# A session that loaded the full agent set, including the relay.
S_CX="test-session-codex"
printf '{"model":"opus","via":"sessionstart","agents":["scout","worker","architect","codex"]}' > "$SESS/$S_CX.json"

# field() pulls an arbitrary dotted field out of updatedInput, so the offload
# tests can assert on the rewritten prompt as well as the type and model.
field() {
  local name="$1" path="$2" expect="$3" payload="$4" got
  got="$(printf '%s' "$payload" | sh "$RUN" "$GATE" 2>/dev/null | "$NODE" -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      try{
        const u=JSON.parse(s).hookSpecificOutput.updatedInput;
        const v=process.argv[1].split(".").reduce((o,k)=>o?.[k],u);
        process.stdout.write(v===undefined||v===null?"(none)":String(v));
      }catch{process.stdout.write("NOOP")}})' "$path")"
  if [ "$got" = "$expect" ]; then
    printf '  \033[32mPASS\033[0m  %-46s -> %s\n' "$name" "$got"; PASS=$((PASS+1))
  else
    printf '  \033[31mFAIL\033[0m  %-46s -> %s (expected %s)\n' "$name" "$got" "$expect"; FAIL=$((FAIL+1))
  fi
}
# grepfield() asserts a field CONTAINS a string — for the prompt preamble.
grepfield() {
  local name="$1" path="$2" needle="$3" payload="$4" got
  got="$(printf '%s' "$payload" | sh "$RUN" "$GATE" 2>/dev/null | "$NODE" -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      try{
        const u=JSON.parse(s).hookSpecificOutput.updatedInput;
        const v=process.argv[1].split(".").reduce((o,k)=>o?.[k],u);
        process.stdout.write(String(v).includes(process.argv[2])?"yes":"no");
      }catch{process.stdout.write("NOOP")}})' "$path" "$needle")"
  if [ "$got" = "yes" ]; then
    printf '  \033[32mPASS\033[0m  %-46s -> %s\n' "$name" "$got"; PASS=$((PASS+1))
  else
    printf '  \033[31mFAIL\033[0m  %-46s -> %s (expected yes)\n' "$name" "$got"; FAIL=$((FAIL+1))
  fi
}

CXTAG='"subagent_type":"general-purpose","description":"[gpt] review the parser","prompt":"review the parser for correctness"'
redirect  "[gpt] swaps the type for the relay"     codex       "$(agent $S_CX "$CXTAG")"
check     "...and the relay runs on haiku"         haiku       "$(agent $S_CX "$CXTAG")"
grepfield "...carrying a CODEX-OFFLOAD preamble"   prompt "CODEX-OFFLOAD:"                "$(agent $S_CX "$CXTAG")"
grepfield "...that names the scored tier's model"  prompt "model: gpt-5.6-terra"          "$(agent $S_CX "$CXTAG")"
grepfield "...and the original task survives it"   prompt "review the parser for correct" "$(agent $S_CX "$CXTAG")"

# [gpt] wins over [hard], and [hard]'s tier (now opus) picks that tier's OpenAI model.
BOTH='"subagent_type":"general-purpose","description":"[gpt] [hard] design it","prompt":"design the new schema"'
redirect  "[gpt] beats [hard]: still the relay"    codex  "$(agent $S_CX "$BOTH")"
grepfield "...but [hard] picks the opus-tier GPT model"  prompt "model: gpt-5.6-terra" "$(agent $S_CX "$BOTH")"

# The guards. Each of these must stay on Anthropic.
redirect "no tag + empty autoTiers -> no offload"  general-purpose "$(agent $S_CX '"subagent_type":"general-purpose","description":"d","prompt":"summarise the release notes for me please"')"
redirect "specialised built-in never offloads"     Explore "$(agent $S_CX '"subagent_type":"Explore","description":"[gpt] find it","prompt":"find the auth config"')"
redirect "session without the relay loaded"        scout   "$(agent $SESSION_READY '"subagent_type":"general-purpose","description":"[gpt] find it","prompt":"find the auth config"')"
redirect "transcript-recovered session: no offload" general-purpose "$(agent $SESSION_LEGACY '"subagent_type":"general-purpose","description":"[gpt] review it","prompt":"review the parser"')"

# The mechanical tier is excluded by neverAutoTiers even if someone opts it in,
# because a subprocess round-trip costs more latency than the spawn costs money.
redirect "[gpt] on a mechanical task still relays" codex "$(agent $S_CX '"subagent_type":"general-purpose","description":"[gpt] find it","prompt":"find the auth config"')"
grepfield "...on the cheap GPT model"              prompt "model: gpt-5.6-sol" "$(agent $S_CX '"subagent_type":"general-purpose","description":"[gpt] find it","prompt":"find the auth config"')"

# Pairing: the logged hash must match the prompt the subagent actually receives,
# or SubagentStop can never join an offloaded spawn back to its routing decision.
printf '%s' "$(agent $S_CX "$CXTAG")" | sh "$RUN" "$GATE" >/dev/null 2>&1
# sonnet, not opus: "review the parser" matches no expensive verb, so it scores
# base — and the offload row must record THAT, not the session's own tier.
assert "offload row records the scored tier" "sonnet" \
  "$("$NODE" -e '
    const l=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse);
    const r=l.filter(x=>x.offload==="codex").pop(); process.stdout.write(r?.scored_tier??"(none)")' "$LEDG")"
assert "offload row names the OpenAI model"  "gpt-5.6-terra" \
  "$("$NODE" -e '
    const l=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse);
    const r=l.filter(x=>x.offload==="codex").pop(); process.stdout.write(r?.offload_model??"(none)")' "$LEDG")"
assert "offload row hashes the REWRITTEN prompt" "match" \
  "$(printf '%s' "$(agent $S_CX "$CXTAG")" | sh "$RUN" "$GATE" 2>/dev/null | "$NODE" --input-type=module -e '
      import {readFileSync} from "node:fs";
      import {promptHash} from "'"$DIR"'/hooks/lib.mjs";
      let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
        const u=JSON.parse(s).hookSpecificOutput.updatedInput;
        const l=readFileSync("'"$LEDG"'","utf8").trim().split("\n").map(x=>JSON.parse(x));
        const r=l.filter(x=>x.offload==="codex").pop();
        process.stdout.write(promptHash(u.prompt)===r.prompt_sha?"match":"MISMATCH");
      })')"

echo
echo "== Codex offload: the fixes from the 2026-09-16 review =="

# [R3] The preamble must be separable from the task, or the relay forwards its own
# instructions and the worker is told to become another relay.
grepfield "preamble carries a task-begins marker" prompt "CODEX-TASK-BEGINS" "$(agent $S_CX "$CXTAG")"
assert "marker splits preamble from task cleanly" "review the parser for correctness" \
  "$(printf '%s' "$(agent $S_CX "$CXTAG")" | sh "$RUN" "$GATE" 2>/dev/null | "$NODE" -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      const p=JSON.parse(s).hookSpecificOutput.updatedInput.prompt;
      const m="--- CODEX-TASK-BEGINS (send only what follows) ---";
      process.stdout.write(p.slice(p.indexOf(m)+m.length).trim());
    })')"

# [R8] The preamble is longer than a fingerprint, so without stripping, every
# offload with the same model/effort fingerprints identically and the gated/ungated
# provenance check in log.mjs reports false positives.
assert "fingerprints still discriminate by task" "differ" \
  "$("$NODE" --input-type=module -e '
    import {promptFingerprint, CODEX_TASK_MARKER as M} from "'"$DIR"'/hooks/lib.mjs";
    /* Built to the REAL envelope shape (header + model/effort/wrapper + marker);
       the stripper matches that structure, not a length window or a bare prefix. */
    const pre="CODEX-OFFLOAD:\n  model: gpt-5.6-terra\n  effort: medium\n  wrapper: /some/install/bin/codex-relay.sh\n\nrelay instructions that run well past one hundred characters in total length\n\n"+M+"\n\n";
    const a=promptFingerprint(pre+"review the parser for correctness");
    const b=promptFingerprint(pre+"review the tokeniser for correctness");
    process.stdout.write(a===b?"SAME":"differ");
  ')"
assert "stripped fingerprint equals the bare task" "match" \
  "$("$NODE" --input-type=module -e '
    import {promptFingerprint, CODEX_TASK_MARKER as M} from "'"$DIR"'/hooks/lib.mjs";
    const pre="CODEX-OFFLOAD:\n  model: gpt-5.6-terra\n  effort: medium\n  wrapper: /some/install/bin/codex-relay.sh\n\nrelay instructions\n\n"+M+"\n\n";
    const t="review the parser for correctness";
    process.stdout.write(promptFingerprint(pre+t)===promptFingerprint(t)?"match":"MISMATCH");
  ')"
# A marker deep inside caller-supplied text is content, not routing metadata.
# (The earlier version of this compared a call with itself and could not fail.)
assert "a late marker leaves the fingerprint alone" "match" \
  "$("$NODE" --input-type=module -e '
    import {promptFingerprint, CODEX_TASK_MARKER as M} from "'"$DIR"'/hooks/lib.mjs";
    const long="x".repeat(900)+"\n"+M+"\ntail";
    const bare="x".repeat(900);
    /* the fingerprint keeps 100 chars, so an unstripped long prompt matches the
       same leading text; a STRIPPED one would fingerprint as "tail" instead. */
    process.stdout.write(promptFingerprint(long)===promptFingerprint(bare)?"match":"MISMATCH");
  ')"
# A task that legitimately QUOTES the protocol must not be mistaken for one.
# Reproduced by Codex: matching the bare `CODEX-OFFLOAD:` prefix stripped a
# documentation example about this very feature down to its suffix.
assert "a task quoting the protocol is not stripped" "kept" \
  "$("$NODE" --input-type=module -e '
    import {stripOffloadPreamble, CODEX_TASK_MARKER as M} from "'"$DIR"'/hooks/lib.mjs";
    const t="CODEX-OFFLOAD: this is a literal documentation example.\nLater we mention "+M+" too.\nsuffix";
    process.stdout.write(stripOffloadPreamble(t)===t?"kept":"STRIPPED");
  ')"

assert "...and its text is preserved, not stripped" "kept" \
  "$("$NODE" --input-type=module -e '
    import {stripOffloadPreamble, CODEX_TASK_MARKER as M} from "'"$DIR"'/hooks/lib.mjs";
    const long="y".repeat(900)+"\n"+M+"\ntail";
    process.stdout.write(stripOffloadPreamble(long)===long?"kept":"STRIPPED");
  ')"

# [R6] The tierIndex guard ran on the scored tier; the offload branch then replaced
# it with relayTier, which nothing validated. A typo there broke the spawn.
# Drive the GATE with a policy whose relayTier is a typo, rather than asserting
# on tierIndex() directly — the point is that the gate refuses to emit it.
"$NODE" -e 'const fs=require("fs");const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  p.codex.relayTier="haku";fs.writeFileSync(process.argv[2],JSON.stringify(p));' \
  "$DIR/policy.json" "$SANDBOX/bad-relay.json"
got="$(printf '%s' "$(agent $S_CX "$CXTAG")" \
  | env MODEL_POLICY_POLICY="$SANDBOX/bad-relay.json" sh "$RUN" "$GATE" 2>/dev/null)"
if [ -z "$got" ]; then
  printf '  \033[32mPASS\033[0m  %-46s -> %s\n' "a bogus relayTier is refused, not emitted" "NOOP"; PASS=$((PASS+1))
else
  printf '  \033[31mFAIL\033[0m  %-46s -> %s (expected NOOP)\n' "a bogus relayTier is refused, not emitted" "$got"; FAIL=$((FAIL+1))
fi

# [R4] Naming the relay directly is a second entrance to the subprocess. With
# offloading enabled it must become a proper offload (with routing metadata);
# with it disabled it must be refused outright.
redirect  "direct relay call stays on the relay"  codex "$(agent $S_CX '"subagent_type":"codex","description":"d","prompt":"review the parser"')"
grepfield "...and gains a validated preamble"     prompt "CODEX-OFFLOAD:" "$(agent $S_CX '"subagent_type":"codex","description":"d","prompt":"review the parser"')"

STUBDIR="$SANDBOX/stubbin"; mkdir -p "$STUBDIR"
# Created HERE, before the first wrapper invocation: the wrapper checks
# `command -v codex` before validating its arguments, so on a machine with no
# real Codex the sandbox-rejection test failed with "codex CLI not found"
# instead of the error it was asserting.
cat > "$STUBDIR/codex" <<'STUB'
#!/usr/bin/env bash
# Stand-in worker. Records the argv it was given so the suite can assert that the
# wrapper actually passes model/effort/sandbox through — a stub that ignores them
# would keep those tests green while the wrapper dropped the flags entirely.
out=""; model=""; effort=""; sandbox=""
argv=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -m) model="$2"; shift 2 ;;
    -s) sandbox="$2"; shift 2 ;;
    -c) effort="${2#model_reasoning_effort=}"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "${argv[@]}" > "${STUB_ARGV_LOG:-/dev/null}"
task="$(cat)"
case "$task" in
  *SPAWNCHILD*) sleep 120 & printf '%s' "$!" > "${STUB_CHILD_PID:-/dev/null}"; sleep 120 ;;
  *EXITGRACE*)
      # Leader completes normally, child still needs TERM grace. Covers the
      # post-completion sweep, which a timeout test cannot reach.
      bash -c 'trap "sleep 1; printf done > \"$1\"; exit 0" TERM; sleep 120' _ "${STUB_GRACE_FILE:-/dev/null}" &
      printf '%s' "$!" > "${STUB_CHILD_PID:-/dev/null}"
      printf 'STUB-ANSWER\n' > "$out"
      exit 0 ;;
  *GRACECHILD*)
      # A child that needs real grace: it catches TERM, takes ~1s, then records
      # that it finished cleanly. GRACE_SECONDS=0 would lose that file.
      bash -c 'trap "sleep 1; printf done > \"$1\"; exit 0" TERM; sleep 120' _ "${STUB_GRACE_FILE:-/dev/null}" &
      printf '%s' "$!" > "${STUB_CHILD_PID:-/dev/null}"
      sleep 120 ;;
  *HANG*)       printf '%s' "$$" > "${STUB_SELF_PID:-/dev/null}"; sleep 120 ;;
  *FAIL*)       exit 7 ;;
esac
printf 'STUB-ANSWER model=%s effort=%s sandbox=%s\n' "$model" "$effort" "$sandbox" > "$out"
STUB
chmod +x "$STUBDIR/codex"

# [R4] The kill switch has to cover BOTH entrances: the gate (routing) and the
# wrapper (execution). A disabled offload that can still be reached by naming the
# relay agent directly is not disabled.
"$NODE" -e '
  const fs=require("fs");
  const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  p.codex.enabled=false;
  fs.writeFileSync(process.argv[2],JSON.stringify(p));' "$DIR/policy.json" "$SANDBOX/codex-off.json"

got="$(printf '%s' "$(agent $S_CX '"subagent_type":"codex","description":"d","prompt":"review the parser"')" \
  | env MODEL_POLICY_POLICY="$SANDBOX/codex-off.json" sh "$RUN" "$GATE" 2>/dev/null)"
if printf '%s' "$got" | grep -q '"permissionDecision":"deny"'; then
  printf '  \033[32mPASS\033[0m  %-46s -> %s\n' "disabled: direct relay spawn is denied" "DENY"; PASS=$((PASS+1))
else
  printf '  \033[31mFAIL\033[0m  %-46s -> %s (expected DENY)\n' "disabled: direct relay spawn is denied" "${got:-NOOP}"; FAIL=$((FAIL+1))
fi

got="$(printf '%s' "$(agent $S_CX "$CXTAG")" \
  | env MODEL_POLICY_POLICY="$SANDBOX/codex-off.json" sh "$RUN" "$GATE" 2>/dev/null \
  | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      try{process.stdout.write(JSON.parse(s).hookSpecificOutput.updatedInput.subagent_type||"(empty)")}catch{process.stdout.write("NOOP")}})')"
if [ "$got" != "codex" ]; then
  printf '  \033[32mPASS\033[0m  %-46s -> %s\n' "disabled: [gpt] does not offload" "$got"; PASS=$((PASS+1))
else
  printf '  \033[31mFAIL\033[0m  %-46s -> %s (expected not codex)\n' "disabled: [gpt] does not offload" "$got"; FAIL=$((FAIL+1))
fi

# The wrapper enforces it independently of the gate.
out="$(env MODEL_POLICY_POLICY="$SANDBOX/codex-off.json" PATH="$STUBDIR:$PATH" bash "$DIR/bin/codex-relay.sh" --task "$DIR/policy.json" 2>&1)"
if printf '%s' "$out" | grep -q 'disabled'; then
  printf '  \033[32mPASS\033[0m  %-46s -> %s\n' "disabled: the wrapper refuses to run" "refused"; PASS=$((PASS+1))
else
  printf '  \033[31mFAIL\033[0m  %-46s -> %s\n' "disabled: the wrapper refuses to run" "$out"; FAIL=$((FAIL+1))
fi

# Wrapper argument validation, without invoking codex at all.
for pair in "danger-full-access:unsupported sandbox" "read-only:"; do
  mode="${pair%%:*}"; want="${pair#*:}"
  [ -z "$want" ] && continue
  out="$(PATH="$STUBDIR:$PATH" bash "$DIR/bin/codex-relay.sh" --task "$DIR/policy.json" --sandbox "$mode" 2>&1)"
  if printf '%s' "$out" | grep -q "$want"; then
    printf '  \033[32mPASS\033[0m  %-46s -> %s\n' "wrapper rejects sandbox escalation" "refused"; PASS=$((PASS+1))
  else
    printf '  \033[31mFAIL\033[0m  %-46s -> %s\n' "wrapper rejects sandbox escalation" "$out"; FAIL=$((FAIL+1))
  fi
done
out="$(PATH="$STUBDIR:$PATH" bash "$DIR/bin/codex-relay.sh" --task /does/not/exist.md 2>&1)"
if printf '%s' "$out" | grep -q 'does not exist'; then
  printf '  \033[32mPASS\033[0m  %-46s -> %s\n' "wrapper rejects a missing task file" "refused"; PASS=$((PASS+1))
else
  printf '  \033[31mFAIL\033[0m  %-46s -> %s\n' "wrapper rejects a missing task file" "$out"; FAIL=$((FAIL+1))
fi

# [R5] A direct `codex` spawn must score the TASK, not the courier. resolveTier
# clamps to the agent definition's declared model, and the relay declares haiku —
# so the worker tier was being read off the courier's cost. A hard task submitted
# directly resolved to gpt-5.6-sol/low while the same prompt via [gpt] on
# general-purpose resolved to gpt-5.6-terra/high. Same work, weaker worker,
# clean exit hiding it.
HARDPROMPT='"subagent_type":"codex","description":"d","prompt":"debug the failing consensus regression and find the root cause"'
grepfield "direct call scores the task, not the relay" prompt "model: gpt-5.6-terra" "$(agent $S_CX "$HARDPROMPT")"
grepfield "...at the tier the task earned"             prompt "effort: high"         "$(agent $S_CX "$HARDPROMPT")"
# The same prompt through the generic path must agree — that is the whole point.
GENERIC_HARD='"subagent_type":"general-purpose","description":"[gpt] d","prompt":"debug the failing consensus regression and find the root cause"'
grepfield "...matching the [gpt] route for that task"  prompt "model: gpt-5.6-terra" "$(agent $S_CX "$GENERIC_HARD")"
grepfield "...including its effort, not just model"    prompt "effort: high"         "$(agent $S_CX "$GENERIC_HARD")"

# [R12] Exercise log.mjs against a real transcript rather than asserting on
# promptHash twice. A prompt split across text blocks must still join.
S_LOG="test-session-logjoin"
printf '{"model":"opus","via":"sessionstart","agents":["scout","worker","architect","codex"]}' > "$SESS/$S_LOG.json"
SPLIT_TS="$SANDBOX/split-transcript.jsonl"
"$NODE" -e '
  const fs=require("fs");
  const rows=[
    {type:"user",message:{content:[{type:"text",text:"alpha "},{type:"text",text:"beta gamma"}]}},
    {type:"assistant",message:{model:"claude-haiku-4-5-20251001",usage:{input_tokens:5,output_tokens:7}}}
  ];
  fs.writeFileSync(process.argv[1],rows.map(r=>JSON.stringify(r)).join("\n")+"\n");' "$SPLIT_TS"
printf '{"session_id":"%s","agent_id":"split1","agent_type":"general-purpose","agent_transcript_path":"%s"}' "$S_LOG" "$SPLIT_TS" \
  | sh "$RUN" "$LOG" >/dev/null 2>&1
assert "log.mjs joins split text blocks" "$("$NODE" --input-type=module -e '
    import {promptHash} from "'"$DIR"'/hooks/lib.mjs"; process.stdout.write(promptHash("alpha beta gamma"));')" \
  "$("$NODE" -e '
    const l=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").map(x=>JSON.parse(x));
    const r=l.filter(x=>x.event==="complete"&&x.agent_id==="split1").pop();
    process.stdout.write(r?.prompt_sha??"(none)")' "$LEDG")"
rm -f "$SESS/$S_LOG.json" "$SESS/$S_LOG.events"

# [R12] Drive the wrapper against a STUB codex so success and failure are
# exercised without a network call, and so a broken worker cannot pass silently.
mkdir -p "$SANDBOX/wraptmp"
export TMPDIR="$SANDBOX/wraptmp"   # keep wrapper output dirs inside the sandbox
printf 'please do the thing\n' > "$SANDBOX/stub-task.md"
out="$(PATH="$STUBDIR:$PATH" bash "$DIR/bin/codex-relay.sh" --task "$SANDBOX/stub-task.md" --model gpt-5.6-sol --effort low 2>&1)"
assert "wrapper reports a successful worker run" "true" \
  "$(printf '%s' "$out" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(JSON.parse(s).ok))}catch{process.stdout.write("BADJSON")}})')"
assert "...and the answer lands in output_file" "yes" \
  "$(cat "$(printf '%s' "$out" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).output_file))')" 2>/dev/null | grep -q '^STUB-ANSWER' && echo yes || echo no)"
printf 'please FAIL now\n' > "$SANDBOX/stub-fail.md"
out="$(PATH="$STUBDIR:$PATH" bash "$DIR/bin/codex-relay.sh" --task "$SANDBOX/stub-fail.md" --model gpt-5.6-sol --effort low 2>&1)"
assert "wrapper passes model/effort/sandbox through" "gpt-5.6-sol|low|read-only" \
  "$(PATH="$STUBDIR:$PATH" STUB_ARGV_LOG="$SANDBOX/argv.log" bash "$DIR/bin/codex-relay.sh" \
       --task "$SANDBOX/stub-task.md" --model gpt-5.6-sol --effort low --sandbox read-only >/dev/null 2>&1
     "$NODE" -e '
       const a=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n");
       const at=(f)=>a[a.indexOf(f)+1];
       process.stdout.write([at("-m"),at("-c").replace("model_reasoning_effort=",""),at("-s")].join("|"));
     ' "$SANDBOX/argv.log")"

# [R1/R2] The lifecycle findings: a timeout must reap the worker AND its
# descendants, and signalling the wrapper must not orphan them. None of the
# earlier stub tests could have caught either — the stub exited immediately.
printf 'SPAWNCHILD please\n' > "$SANDBOX/stub-child.md"
rm -f "$SANDBOX/child.pid"
LIFE_OUT="$(PATH="$STUBDIR:$PATH" STUB_CHILD_PID="$SANDBOX/child.pid" bash "$DIR/bin/codex-relay.sh" \
  --task "$SANDBOX/stub-child.md" --model gpt-5.6-sol --effort low --timeout 2 2>/dev/null)"
CHILD="$(cat "$SANDBOX/child.pid" 2>/dev/null)"
# A worker that never started would make the orphan check vacuously pass, so
# require evidence that there WAS a descendant, and that the run really timed out.
if [ -z "$CHILD" ]; then
  printf '  \033[31mFAIL\033[0m  %-46s -> %s\n' "timeout reaps the worker's descendants" "NO WORKER STARTED"; FAIL=$((FAIL+1))
elif kill -0 "$CHILD" 2>/dev/null; then
  kill -9 "$CHILD" 2>/dev/null
  printf '  \033[31mFAIL\033[0m  %-46s -> %s\n' "timeout reaps the worker's descendants" "ORPHANED pid $CHILD"; FAIL=$((FAIL+1))
else
  printf '  \033[32mPASS\033[0m  %-46s -> %s\n' "timeout reaps the worker's descendants" "reaped pid $CHILD"; PASS=$((PASS+1))
fi
assert "...and reports the timeout as the reason" "yes" \
  "$(printf '%s' "$LIFE_OUT" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const r=JSON.parse(s);process.stdout.write(r.ok===false&&/timed out/.test(r.reason||"")?"yes":"no:"+(r.reason||""))}catch{process.stdout.write("BADJSON")}})')"
assert "...emitting exactly one JSON object" "1" \
  "$(printf '%s' "$LIFE_OUT" | grep -c '^{')"

printf 'HANG please\n' > "$SANDBOX/stub-hang.md"
rm -f "$SANDBOX/hang.pid"
PATH="$STUBDIR:$PATH" STUB_SELF_PID="$SANDBOX/hang.pid" bash "$DIR/bin/codex-relay.sh" \
  --task "$SANDBOX/stub-hang.md" --model gpt-5.6-sol --effort low --timeout 60 >"$SANDBOX/hang.json" 2>/dev/null &
WRAP=$!
# Wait for the worker to actually exist rather than assuming a fixed sleep is
# enough — a worker that never started made this test vacuously pass.
HANGPID=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  HANGPID="$(cat "$SANDBOX/hang.pid" 2>/dev/null)"
  [ -n "$HANGPID" ] && break
  sleep 0.5
done
if [ -z "$HANGPID" ] || ! kill -0 "$HANGPID" 2>/dev/null; then
  printf '  \033[31mFAIL\033[0m  %-46s -> %s\n' "cancelling the wrapper tears the worker down" "NO WORKER STARTED"; FAIL=$((FAIL+1))
  kill -9 "$WRAP" 2>/dev/null
else
  kill -TERM "$WRAP" 2>/dev/null
  wait "$WRAP" 2>/dev/null
  GONE=no
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$HANGPID" 2>/dev/null || { GONE=yes; break; }
    sleep 0.5
  done
  if [ "$GONE" = yes ]; then
    printf '  \033[32mPASS\033[0m  %-46s -> %s\n' "cancelling the wrapper tears the worker down" "torn down pid $HANGPID"; PASS=$((PASS+1))
  else
    # Kill only the PID THIS test started — a global pkill could take out a
    # concurrently running suite's workers.
    kill -9 "$HANGPID" 2>/dev/null
    printf '  \033[31mFAIL\033[0m  %-46s -> %s\n' "cancelling the wrapper tears the worker down" "SURVIVED pid $HANGPID"; FAIL=$((FAIL+1))
  fi
  assert "cancellation emits exactly one JSON object" "1" "$(grep -c '^{' "$SANDBOX/hang.json" 2>/dev/null || echo 0)"
fi


# Codex proved the suite could not catch two mutations: GRACE_SECONDS=0, and
# cancellation reported as ok=true. Both are covered now.
printf 'GRACECHILD please\n' > "$SANDBOX/stub-grace.md"
rm -f "$SANDBOX/grace.done" "$SANDBOX/child.pid"
PATH="$STUBDIR:$PATH" STUB_CHILD_PID="$SANDBOX/child.pid" STUB_GRACE_FILE="$SANDBOX/grace.done" \
  bash "$DIR/bin/codex-relay.sh" --task "$SANDBOX/stub-grace.md" \
  --model gpt-5.6-sol --effort low --timeout 2 >/dev/null 2>&1
assert "a descendant gets its TERM grace to clean up" "done" \
  "$(cat "$SANDBOX/grace.done" 2>/dev/null || echo MISSING)"

printf 'HANG please\n' > "$SANDBOX/stub-cancel2.md"
rm -f "$SANDBOX/hang2.pid"
PATH="$STUBDIR:$PATH" STUB_SELF_PID="$SANDBOX/hang2.pid" bash "$DIR/bin/codex-relay.sh" \
  --task "$SANDBOX/stub-cancel2.md" --model gpt-5.6-sol --effort low --timeout 60 \
  >"$SANDBOX/cancel2.json" 2>/dev/null &
W2=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$SANDBOX/hang2.pid" ] && break; sleep 0.5; done
kill -TERM "$W2" 2>/dev/null; wait "$W2" 2>/dev/null
# Parse the whole result: counting lines that start with { let a mutation
# reporting cancellation as a success sail straight through.
assert "cancellation reports ok=false with a reason" "yes" \
  "$("$NODE" -e '
    let s=require("fs").readFileSync(process.argv[1],"utf8");
    try{const r=JSON.parse(s.trim().split("\n").filter(Boolean).pop());
      process.stdout.write(r.ok===false && /cancelled/.test(r.reason||"") ? "yes" : "no:"+r.ok+"/"+(r.reason||""));
    }catch(e){process.stdout.write("BADJSON")}' "$SANDBOX/cancel2.json")"

# Teardown status must be reported, and must never say "clean" alongside a
# surviving process — a warning buried in `reason` while ok stayed true was
# invisible to the relay, which branches on ok.
assert "teardown status is reported on cancellation" "yes" \
  "$("$NODE" -e '
    let s=require("fs").readFileSync(process.argv[1],"utf8");
    try{const r=JSON.parse(s.trim().split("\n").filter(Boolean).pop());
      process.stdout.write(typeof r.teardown==="string"&&r.teardown.length>0?"yes":"no:"+r.teardown);
    }catch(e){process.stdout.write("BADJSON")}' "$SANDBOX/cancel2.json")"

# An install path containing a space must still strip: `\S+` on the wrapper line
# silently disabled stripping and put routing metadata back in every fingerprint.
assert "envelope with a spaced wrapper path strips" "match" \
  "$("$NODE" --input-type=module -e '
    import {promptFingerprint, CODEX_TASK_MARKER as M} from "'"$DIR"'/hooks/lib.mjs";
    const pre="CODEX-OFFLOAD:\n  model: gpt-5.6-terra\n  effort: medium\n  wrapper: /Users/Matt Smith/.claude-shared/model-policy/bin/codex-relay.sh\n\ninstructions\n\n"+M+"\n\n";
    const t="review the parser for correctness";
    process.stdout.write(promptFingerprint(pre+t)===promptFingerprint(t)?"match":"MISMATCH");
  ')"

# The marker must be its own LINE. Mentioning it mid-sentence is content.
assert "an inline marker mention does not split" "kept" \
  "$("$NODE" --input-type=module -e '
    import {stripOffloadPreamble, CODEX_TASK_MARKER as M} from "'"$DIR"'/hooks/lib.mjs";
    const t="CODEX-OFFLOAD:\n  model: x\n  effort: y\n  wrapper: /z\n\nprose mentioning "+M+" inline.\nrest";
    const out=stripOffloadPreamble(t);
    process.stdout.write(out===t?"kept":"SPLIT");
  ')"


# [R6-3] Two paths the suite could not see. Both of these mutations passed
# 137/137 before these tests existed.

# (a) A leader that exits NORMALLY with a child still cleaning up. The timeout
# test cannot reach this path — its leader is still running.
printf 'EXITGRACE please\n' > "$SANDBOX/stub-exitgrace.md"
rm -f "$SANDBOX/exitgrace.done" "$SANDBOX/child.pid"
PATH="$STUBDIR:$PATH" STUB_CHILD_PID="$SANDBOX/child.pid" STUB_GRACE_FILE="$SANDBOX/exitgrace.done" \
  bash "$DIR/bin/codex-relay.sh" --task "$SANDBOX/stub-exitgrace.md" \
  --model gpt-5.6-sol --effort low --timeout 30 >/dev/null 2>&1
assert "a completed leader's child still gets grace" "done" \
  "$(cat "$SANDBOX/exitgrace.done" 2>/dev/null || echo MISSING)"

# (b) Inspection failing must fail CLOSED: a successful worker whose process
# group cannot be inspected is not a clean run, because surviving work would be
# invisible. Simulated with a `ps` that always fails.
PSSTUB="$SANDBOX/psstub"; mkdir -p "$PSSTUB"
printf '#!/usr/bin/env bash\nexit 1\n' > "$PSSTUB/ps"; chmod +x "$PSSTUB/ps"
PSOUT="$(PATH="$PSSTUB:$STUBDIR:$PATH" bash "$DIR/bin/codex-relay.sh" \
  --task "$SANDBOX/stub-task.md" --model gpt-5.6-sol --effort low --timeout 30 2>/dev/null)"
assert "uninspectable group fails closed as unknown" "yes" \
  "$(printf '%s' "$PSOUT" | "$NODE" -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      try{const r=JSON.parse(s.trim().split("\n").filter(Boolean).pop());
        process.stdout.write(r.ok===false && /^unknown/.test(r.teardown||"") ? "yes" : "no:"+r.ok+"/"+(r.teardown||""));
      }catch(e){process.stdout.write("BADJSON")}})')"

# ...and the inverse: an ordinary clean run must report teardown clean, or the
# fail-closed rule above would make every success look suspect.
CLEANOUT="$(PATH="$STUBDIR:$PATH" bash "$DIR/bin/codex-relay.sh" \
  --task "$SANDBOX/stub-task.md" --model gpt-5.6-sol --effort low --timeout 30 2>/dev/null)"
assert "an ordinary successful run is teardown clean" "yes" \
  "$(printf '%s' "$CLEANOUT" | "$NODE" -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      try{const r=JSON.parse(s.trim().split("\n").filter(Boolean).pop());
        process.stdout.write(r.ok===true && r.teardown==="clean" ? "yes" : "no:"+r.ok+"/"+(r.teardown||""));
      }catch(e){process.stdout.write("BADJSON")}})')"

assert "wrapper surfaces a nonzero worker exit" "codex exited 7" \
  "$(printf '%s' "$out" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).reason||"(none)")}catch{process.stdout.write("BADJSON")}})')"

# [R1] availableAgents must report what is INSTALLED. Reading the package's own
# agents/ claims an agent exists that Claude Code never loaded, and the gate then
# rewrites subagent_type to a type that does not exist — killing the spawn.
mkdir -p "$SANDBOX/fake-agents"
printf -- '---\nname: only-this\n---\nbody\n' > "$SANDBOX/fake-agents/only-this.md"
assert "availableAgents reads the config dirs" "only-this" \
  "$(env MODEL_POLICY_AGENT_DIRS="$SANDBOX/fake-agents" "$NODE" --input-type=module -e '
    import {availableAgents} from "'"$DIR"'/hooks/lib.mjs";
    const a=availableAgents();
    process.stdout.write(a.includes("only-this")&&!a.includes("scout")?"only-this":a.join(","));
  ')"

echo
echo "== Workflow shim: effort is filled even when the model was chosen =="
# effortByTier.fable was unreachable: the scorer never returns fable, and the only
# way to get a fable workflow agent is an explicit model, which used to skip the
# effort fill entirely. The config edit was dead until this changed.
# Written to a file, not passed via -e inside $(...): macOS /bin/bash 3.2 mangles the
# regex backslashes in a single-quoted string nested in a command substitution, so the
# shim extraction came back empty and the test failed only on a Mac.
cat > "$SANDBOX/effort-fill.mjs" <<'JS'
    const {injectWorkflowTiers, loadPolicy} = await import(process.env.MP_LIB);
    const src = "export const meta={name:\"t\",description:\"d\"};\nawait agent(\"do the thing\", {model: \"fable\"});\n";
    const out = injectWorkflowTiers(src, loadPolicy(), "opus");
    const s = typeof out === "string" ? out : (out?.source ?? out?.script ?? String(out));
    /* Run the shim body against a stub agent() to observe what it actually sets. */
    /* Pull BOTH helpers: __mpAgent calls __mpTier, so extracting only the
       former yields a ReferenceError that looks like a product bug. */
    const grab = (name) => (s.match(new RegExp("function "+name+"[\\s\\S]*?\\n}"))||[""])[0];
    const body = grab("__mpTier") + "\n" + grab("__mpAgent");
    const cfg = (s.match(/const __mpCfg = (\{[\s\S]*?\});/)||[])[1];
    const fn = new Function("captured", `
      const __mpCfg = ${cfg};
      const __mpReal = (p,o)=>{captured.push(o);};
      ${body}
      __mpAgent("do the thing", {model:"fable"});
    `);
    const captured=[]; fn(captured);
    process.stdout.write(captured[0].model+"/"+captured[0].effort);
JS
assert "explicit model still gets its tier's effort" "fable/medium" \
  "$(MP_LIB="file://$DIR/hooks/lib.mjs" "$NODE" "$SANDBOX/effort-fill.mjs")"

echo
echo "== Antigravity offload: routing, usage spill and wrapper guards =="
S_AGY="test-session-agy"
printf '{"model":"opus","via":"sessionstart","agents":["scout","worker","architect","codex","agy"],"agy_available":true}' > "$SESS/$S_AGY.json"
AGYTAG='"subagent_type":"general-purpose","description":"[agy] review the parser","prompt":"review the parser for correctness"'
GEMTAG='"subagent_type":"general-purpose","description":"[gemini] review the parser","prompt":"review the parser for correctness"'
redirect "[agy] swaps the type for the relay" agy "$(agent $S_AGY "$AGYTAG")"
grepfield "[agy] carries a gate grant" prompt "grant:" "$(agent $S_AGY "$AGYTAG")"
redirect "[gemini] swaps the type for the relay" agy "$(agent $S_AGY "$GEMTAG")"
grepfield "[gemini] carries a gate grant" prompt "grant:" "$(agent $S_AGY "$GEMTAG")"
FABLE_POLICY="$SANDBOX/agy-fable.json"
"$NODE" -e 'const fs=require("fs");const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));p.overrides.hardTier="fable";fs.writeFileSync(process.argv[2],JSON.stringify(p));' "$DIR/policy.json" "$FABLE_POLICY"
FABLE_OUT="$(printf '%s' "$(agent $S_AGY '"subagent_type":"general-purpose","description":"[agy] [hard] design it","prompt":"design it"')" | env MODEL_POLICY_POLICY="$FABLE_POLICY" sh "$RUN" "$GATE" 2>/dev/null)"
assert "[agy] fable route carries a grant" yes "$(printf '%s' "$FABLE_OUT" | grep -q 'grant:' && echo yes || echo no)"
redirect "[gpt] wins over both agy tags" codex "$(agent $S_AGY '"subagent_type":"general-purpose","description":"[gpt] [agy] [gemini] review","prompt":"review it"')"
grepfield "[agy] wins over Gemini" prompt "grant:" "$(agent $S_AGY '"subagent_type":"general-purpose","description":"[agy] [gemini] review","prompt":"review it"')"
redirect "agy leaves specialised built-ins alone" Explore "$(agent $S_AGY '"subagent_type":"Explore","description":"[agy] review","prompt":"find it"')"
redirect "agy requires its relay at SessionStart" scout "$(agent $SESSION_READY '"subagent_type":"general-purpose","description":"[agy] find","prompt":"find it"')"

# Availability is decided by SessionStart, not by the gate. A record from before
# that field existed must fail closed even if it knows the relay definition.
S_AGY_OLD="test-session-agy-old"
printf '{"model":"opus","via":"sessionstart","agents":["scout","worker","architect","codex","agy"]}' > "$SESS/$S_AGY_OLD.json"
redirect "missing agy availability leaves [agy] native" general-purpose "$(agent $S_AGY_OLD "$AGYTAG")"
redirect "missing agy availability leaves [gemini] native" general-purpose "$(agent $S_AGY_OLD "$GEMTAG")"
assert "missing agy availability adds no relay preamble" no \
  "$(printf '%s' "$(agent $S_AGY_OLD "$AGYTAG")" | sh "$RUN" "$GATE" 2>/dev/null | grep -q 'AGY-OFFLOAD:' && echo yes || echo no)"
check "missing agy availability denies direct relay" DENY \
  "$(agent $S_AGY_OLD '"subagent_type":"agy","description":"direct","prompt":"review the parser"')"

# The snapshot and clock are both injected: tests never touch a real install's
# usage.json and do not depend on wall time.
USAGE="$SANDBOX/usage.json"
auto_agent() { # <snapshot-json-or-empty> <description> <prompt>
  [ -n "$1" ] && printf '%s' "$1" > "$USAGE" || rm -f "$USAGE"
  printf '%s' "$(agent $S_AGY "\"subagent_type\":\"general-purpose\",\"description\":\"$2\",\"prompt\":\"$3\"")" \
    | env MODEL_POLICY_USAGE_SNAPSHOT="$USAGE" MODEL_POLICY_NOW=1000 sh "$RUN" "$GATE" 2>/dev/null \
    | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).hookSpecificOutput.updatedInput.subagent_type)}catch{process.stdout.write("NOOP")}})'
}
# `agent` above emits its own JSON only when piped through the gate, so build these
# payloads directly for the snapshot cases.
spill() { # <snapshot-json-or-empty> <description> <prompt> [session]
  [ -n "$1" ] && printf '%s' "$1" > "$USAGE" || rm -f "$USAGE"
  "$NODE" -e 'process.stdout.write(JSON.stringify({session_id:process.argv[1],tool_use_id:"u",hook_event_name:"PreToolUse",tool_name:"Agent",tool_input:{subagent_type:"general-purpose",description:process.argv[2],prompt:process.argv[3]}}))' "${4:-$S_AGY}" "$2" "$3" \
    | env MODEL_POLICY_USAGE_SNAPSHOT="$USAGE" MODEL_POLICY_NOW=1000 sh "$RUN" "$GATE" 2>/dev/null \
    | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).hookSpecificOutput.updatedInput.subagent_type)}catch{process.stdout.write("NOOP")}})'
}
assert "fresh five-hour usage spills sonnet" agy "$(spill '{"five_hour_pct":80,"ts":999}' "review" "review the parser")"
assert "fresh seven-day usage spills opus" agy "$(spill '{"seven_day_pct":95,"ts":999}' "debug it" "debug the regression")"
assert "stale usage does not spill" general-purpose "$(spill '{"five_hour_pct":99,"ts":1}' "review" "review the parser")"
assert "missing usage does not spill" general-purpose "$(spill '' "review" "review the parser")"
assert "below threshold does not spill" general-purpose "$(spill '{"five_hour_pct":79,"seven_day_pct":94,"ts":999}' "review" "review the parser")"
assert "explicit Gemini tag beats usage spill" agy "$(spill '{"five_hour_pct":99,"ts":999}' "[gemini] review" "review the parser")"
assert "missing agy availability never usage-spills" general-purpose \
  "$(spill '{"five_hour_pct":99,"ts":999}' "review" "review the parser" "$S_AGY_OLD")"
printf '%s' "$(agent $S_AGY "$AGYTAG")" | sh "$RUN" "$GATE" >/dev/null 2>&1
assert "agy ledger records pool and tag route" thirdparty/tag \
  "$("$NODE" -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse);const r=l.filter(x=>x.offload==="agy").pop();process.stdout.write((r?.offload_pool||"")+"/"+(r?.offload_via||""))' "$LEDG")"

assert "agy preamble strips to the bare task" match \
  "$("$NODE" --input-type=module -e '
    import {promptFingerprint, AGY_TASK_MARKER as M} from "'"$DIR"'/hooks/lib.mjs";
    const p="AGY-OFFLOAD:\n  grant: abcd1234\n  wrapper: /Some Path/bin/agy-relay.sh\n\ninstructions\n\n"+M+"\n\n";
    process.stdout.write(promptFingerprint(p+"review it")===promptFingerprint("review it")?"match":"MISMATCH");
  ')"

# The gate's only durable hand-off is the grant on disk.  Assert routing from
# that record rather than from the relay preamble, which is merely instructions
# for the courier and deliberately does not duplicate policy decisions.
agy_route() { # <description> <prompt> <parent-cwd> [policy]
  local desc="$1" prompt="$2" parent="$3" policy="${4:-$DIR/policy.json}"
  AGY_ROUTE_OUT="$("$NODE" -e 'process.stdout.write(JSON.stringify({session_id:process.argv[1],tool_use_id:"agy-grant",hook_event_name:"PreToolUse",tool_name:"Agent",cwd:process.argv[4],tool_input:{subagent_type:"general-purpose",description:process.argv[2],prompt:process.argv[3]}}))' "$S_AGY" "$desc" "$prompt" "$parent" | env MODEL_POLICY_POLICY="$policy" sh "$RUN" "$GATE" 2>/dev/null)"
  AGY_ROUTE_TYPE="$(printf '%s' "$AGY_ROUTE_OUT" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).hookSpecificOutput.updatedInput.subagent_type||"(none)")}catch{process.stdout.write("NOOP")}})')"
  AGY_GRANT_ID="$(printf '%s' "$AGY_ROUTE_OUT" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const p=JSON.parse(s).hookSpecificOutput.updatedInput.prompt;process.stdout.write((p.match(/grant: ([a-f0-9]{48})/)||[,""])[1])}catch{}})')"
  AGY_GRANT="$MODEL_POLICY_GRANTS/$AGY_GRANT_ID.json"
}
agy_grant_field() { "$NODE" -e 'const g=require(process.argv[1]);process.stdout.write(String(g[process.argv[2]]))' "$AGY_GRANT" "$1" 2>/dev/null; }
agy_grant_access_cwd() { "$NODE" -e 'const g=require(process.argv[1]);process.stdout.write(g.access+"|"+g.cwd)' "$AGY_GRANT" 2>/dev/null; }

echo
echo "== Antigravity grants: tiers, precedence, access and spill =="

# Every tier must map to the model for the selected pool.  Each assertion reads
# the immutable record the gate gave the relay, not the now-removed old preamble.
for pool in gemini agy; do
  case "$pool" in
    gemini) tag='[gemini]'; h='gemini-3.8-flash-low'; s='gemini-3.8-flash-medium'; o='gemini-3.1-pro-high'; f='gemini-3.1-pro-high' ;;
    agy) tag='[agy]'; h='gpt-oss-120b-medium'; s='claude-sonnet-4-6'; o='claude-opus-4-6-thinking'; f='claude-opus-4-6-thinking' ;;
  esac
  agy_route "$tag [cheap]" "review this" "$DIR"
  assert "$pool haiku model is recorded in its grant" "$h" "$(agy_grant_field model)"
  agy_route "$tag routine" "review this" "$DIR"
  assert "$pool sonnet model is recorded in its grant" "$s" "$(agy_grant_field model)"
  agy_route "$tag [hard]" "design this" "$DIR"
  assert "$pool opus model is recorded in its grant" "$o" "$(agy_grant_field model)"
  agy_route "$tag [hard]" "design this" "$DIR" "$FABLE_POLICY"
  assert "$pool fable model is recorded in its grant" "$f" "$(agy_grant_field model)"
done

agy_route '[agy] [gemini]' 'review precedence' "$DIR"
assert "[agy] outranks [gemini] in the grant pool" thirdparty "$(agy_grant_field pool)"
GTP_AGY_OUT="$(printf '%s' "$(agent "$S_AGY" '"subagent_type":"general-purpose","description":"[gpt] [agy] review","prompt":"review it"')" | sh "$RUN" "$GATE" 2>/dev/null)"
assert "[gpt] outranks [agy]" codex "$(printf '%s' "$GTP_AGY_OUT" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).hookSpecificOutput.updatedInput.subagent_type)}catch{process.stdout.write("NOOP")}})')"
check "direct agy plus [gpt] is denied" DENY "$(agent "$S_AGY" '"subagent_type":"agy","description":"[gpt] contradicts","prompt":"review it"')"

PARENT_CWD="$SANDBOX/agy-parent"; WT_ONE="$SANDBOX/.worktrees/one"; WT_TWO="$SANDBOX/.worktrees/two"
SUBSTRING_WT="$SANDBOX/my.worktrees2/not-a-worktree"; LINK_WT="$SANDBOX/worktree-link"
mkdir -p "$PARENT_CWD" "$WT_ONE" "$WT_TWO" "$SUBSTRING_WT"
git init -q "$WT_ONE"
ln -s "$WT_ONE" "$LINK_WT"
agy_route '[gemini]' "review $WT_ONE" "$PARENT_CWD"
assert "Gemini worktree request stays read-only in session cwd" "read-only|$PARENT_CWD" "$(agy_grant_access_cwd)"
agy_route '[agy]' 'review without a worktree path' "$PARENT_CWD"
assert "[agy] with zero worktree paths stays read-only" "read-only|$PARENT_CWD" "$(agy_grant_access_cwd)"
agy_route '[agy] [edit]' "review $WT_ONE" "$PARENT_CWD"
assert "[agy] [edit] with one worktree root gets edit access" "edit|$WT_ONE" "$(agy_grant_access_cwd)"
agy_route '[agy]' "review $WT_ONE" "$PARENT_CWD"
assert "[agy] without [edit] remains read-only" "read-only|$PARENT_CWD" "$(agy_grant_access_cwd)"
agy_route '[agy]' "compare $WT_ONE and $WT_TWO" "$PARENT_CWD"
assert "[agy] with two worktree paths stays read-only" "read-only|$PARENT_CWD" "$(agy_grant_access_cwd)"
agy_route '[agy]' "review $SANDBOX/.worktrees/missing" "$PARENT_CWD"
assert "a nonexistent worktree path stays read-only" "read-only|$PARENT_CWD" "$(agy_grant_access_cwd)"
agy_route '[agy]' "review $SUBSTRING_WT" "$PARENT_CWD"
assert "worktrees as a substring is not edit access" "read-only|$PARENT_CWD" "$(agy_grant_access_cwd)"
agy_route '[agy] [edit]' "review $LINK_WT" "$PARENT_CWD"
assert "a symlink into one worktree gets resolved edit access" "edit|$WT_ONE" "$(agy_grant_access_cwd)"
UNSAFE_CWD="$SANDBOX/unsafe-cwd"; mkdir -p "$UNSAFE_CWD/.ssh"
agy_route '[agy]' 'review safely' "$UNSAFE_CWD"
assert "secret-bearing cwd falls back to native routing" general-purpose \
  "$(printf '%s' "$AGY_ROUTE_OUT" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).hookSpecificOutput.updatedInput.subagent_type)}catch{process.stdout.write("general-purpose")}})')"
agy_route '[agy]' 'review safely' "$HOME"
assert "home cwd falls back to native routing" general-purpose \
  "$(printf '%s' "$AGY_ROUTE_OUT" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).hookSpecificOutput.updatedInput.subagent_type)}catch{process.stdout.write("general-purpose")}})')"

# Cwd admission compares path components. These four cases caught the old '/'
# string-prefix bypass and ensure descendants of HOME remain usable.
CWD_HOME="$SANDBOX/cwd-home"; mkdir -p "$CWD_HOME/x"
for pair in "/:false" "/home:false" "$CWD_HOME:false" "$CWD_HOME/x:true"; do
  cwd_case="${pair%:*}"; expected="${pair##*:}"
  assert "agy cwd component guard: $cwd_case" "$expected" \
    "$(HOME="$CWD_HOME" "$NODE" --input-type=module -e 'const {agyCwdAllowed}=await import(process.argv[1]);process.stdout.write(String(agyCwdAllowed(process.argv[2])))' "file://$DIR/hooks/lib.mjs" "$cwd_case")"
done

# Spill inputs are deliberately validated narrowly: JSON coercion must not turn
# a malformed status line into a backend switch.
for bad in '{"five_hour_pct":"99","ts":999}' '{"five_hour_pct":"NaN","ts":999}' '{"five_hour_pct":101,"ts":999}' '{"five_hour_pct":-1,"ts":999}' '{"five_hour_pct":99,"ts":1001}'; do
  assert "invalid or future usage snapshot does not spill" general-purpose "$(spill "$bad" 'review' 'review the parser')"
done
assert "an explicit model does not usage-spill" NOOP "$(printf '%s' '{"session_id":"test-session-agy","tool_use_id":"u","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","description":"review","prompt":"review the parser","model":"sonnet"}}' | env MODEL_POLICY_USAGE_SNAPSHOT="$USAGE" MODEL_POLICY_NOW=1000 sh "$RUN" "$GATE" 2>/dev/null | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(s?"changed":"NOOP"))')"
assert "[hard] does not usage-spill" general-purpose "$(spill '{"five_hour_pct":99,"ts":999}' '[hard] review' 'review the parser')"
assert "[cheap] does not usage-spill" scout "$(spill '{"five_hour_pct":99,"ts":999}' '[cheap] review' 'review the parser')"

# Snapshot names include the resolved config directory so two accounts cannot
# spill one another.  Gate processes must read only their own account's file.
CONFIG_A="$SANDBOX/claude-a"; CONFIG_B="$SANDBOX/claude-b"; mkdir -p "$CONFIG_A" "$CONFIG_B"
printf '%s' '{"rate_limits":{"five_hour":{"used_percentage":99}}}' | CLAUDE_CONFIG_DIR="$CONFIG_A" bash "$DIR/bin/usage-snapshot.sh"
printf '%s' '{"rate_limits":{"five_hour":{"used_percentage":1}}}' | CLAUDE_CONFIG_DIR="$CONFIG_B" bash "$DIR/bin/usage-snapshot.sh"
KEY_A="$("$NODE" -e 'const{createHash}=require("crypto"),fs=require("fs");process.stdout.write(createHash("sha1").update(fs.realpathSync(process.argv[1])).digest("hex").slice(0,12))' "$CONFIG_A")"
KEY_B="$("$NODE" -e 'const{createHash}=require("crypto"),fs=require("fs");process.stdout.write(createHash("sha1").update(fs.realpathSync(process.argv[1])).digest("hex").slice(0,12))' "$CONFIG_B")"
assert "per-account usage writes separate snapshot files" yes "$([ -f "$DIR/usage-$KEY_A.json" ] && [ -f "$DIR/usage-$KEY_B.json" ] && echo yes || echo no)"
ACCOUNT_NOW="$(date +%s)"
ACCOUNT_SPILL() { "$NODE" -e 'process.stdout.write(JSON.stringify({session_id:"test-session-agy",tool_use_id:"u",hook_event_name:"PreToolUse",tool_name:"Agent",tool_input:{subagent_type:"general-purpose",description:"review",prompt:"review the parser"}}))' | env CLAUDE_CONFIG_DIR="$1" MODEL_POLICY_NOW="$ACCOUNT_NOW" sh "$RUN" "$GATE" 2>/dev/null | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).hookSpecificOutput.updatedInput.subagent_type)}catch{process.stdout.write("general-purpose")}})'; }
assert "account A reads only its high-usage snapshot" agy "$(ACCOUNT_SPILL "$CONFIG_A")"
assert "account B reads only its low-usage snapshot" general-purpose "$(ACCOUNT_SPILL "$CONFIG_B")"
rm -f "$DIR/usage-$KEY_A.json" "$DIR/usage-$KEY_B.json"

# codex.tagFrom is an opt-in spelling override, not dead policy surface.
TAGFROM_POLICY="$SANDBOX/codex-tagfrom.json"
"$NODE" -e 'const fs=require("fs");const p=JSON.parse(fs.readFileSync(process.argv[1]));p.codex.tagFrom="[openai]";fs.writeFileSync(process.argv[2],JSON.stringify(p));' "$DIR/policy.json" "$TAGFROM_POLICY"
assert "codex.tagFrom is honoured" codex "$(printf '%s' "$(agent "$S_AGY" '"subagent_type":"general-purpose","description":"[openai] review","prompt":"review it"')" | env MODEL_POLICY_POLICY="$TAGFROM_POLICY" sh "$RUN" "$GATE" 2>/dev/null | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).hookSpecificOutput.updatedInput.subagent_type)}catch{process.stdout.write("NOOP")}})')"

AGY_HOME="$SANDBOX/agy-home"
FAKE_AGY="$AGY_HOME/.local/bin/agy"
mkdir -p "$(dirname "$FAKE_AGY")"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\\n" "$@" > "${AGY_ARGV_LOG:-/dev/null}"' 'if [ -n "${AGY_PLANT_NESTED:-}" ]; then mkdir -p "$PWD/nested/.git"; fi' 'if [ -n "${AGY_SYMLINK_TARGET:-}" ]; then ln -sf "$AGY_SYMLINK_TARGET" /relay/answer.md 2>/dev/null || true; fi' 'if [ -n "${AGY_BIG_ANSWER:-}" ]; then head -c 205000 /dev/zero | tr "\\0" x; else case "$*" in *PERMDENY*) printf "jetski: no output produced\\n" ;; *) printf "AGY-ANSWER\\n" ;; esac; fi' > "$FAKE_AGY"
chmod +x "$FAKE_AGY"
AGY_POLICY="$SANDBOX/agy-policy.json"
"$NODE" -e 'const fs=require("fs");const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));p.agy.binary=process.argv[2];fs.writeFileSync(process.argv[3],JSON.stringify(p));' "$DIR/policy.json" "$FAKE_AGY" "$AGY_POLICY"

# The SessionStart check resolves $HOME once and records the result. The gate
# consumes only that state, so a legacy record cannot accidentally route because
# a binary appears later in the session.
MISSING_AGY_POLICY="$SANDBOX/agy-missing-policy.json"
"$NODE" -e 'const fs=require("fs");const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));p.agy.binary="$HOME/bin/missing-agy";fs.writeFileSync(process.argv[2],JSON.stringify(p));' "$DIR/policy.json" "$MISSING_AGY_POLICY"
S_AGY_MISSING="test-session-agy-missing"
BRIEF_OUT="$(printf '{"session_id":"%s","model":"opus"}' "$S_AGY_MISSING" | env HOME="$SANDBOX/agy-home" MODEL_POLICY_POLICY="$MISSING_AGY_POLICY" sh "$RUN" "$DIR/hooks/brief.mjs" 2>/dev/null)"
assert "SessionStart records missing $HOME agy unavailable" false \
  "$("$NODE" -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).agy_available))' "$SESS/$S_AGY_MISSING.json")"
assert "missing agy brief says tags are inactive" yes \
  "$(printf '%s' "$BRIEF_OUT" | grep -q 'Antigravity tags.*inactive on this machine.*install.sh.*run.*agy.*sign in' && echo yes || echo no)"
assert "missing agy brief omits full offload brief" no \
  "$(printf '%s' "$BRIEF_OUT" | grep -q '## Offloading to Antigravity models' && echo yes || echo no)"
S_AGY_FAKE="test-session-agy-fake"
AGY_AGENT_DIR="$SANDBOX/agy-agents"; mkdir -p "$AGY_AGENT_DIR"
printf -- '---\nname: agy\n---\n' > "$AGY_AGENT_DIR/agy.md"
printf '{"session_id":"%s","model":"opus"}' "$S_AGY_FAKE" \
  | env MODEL_POLICY_POLICY="$AGY_POLICY" MODEL_POLICY_AGENT_DIRS="$AGY_AGENT_DIR" sh "$RUN" "$DIR/hooks/brief.mjs" >/dev/null 2>&1
assert "SessionStart records executable fake agy available" true \
  "$("$NODE" -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).agy_available))' "$SESS/$S_AGY_FAKE.json")"
FAKE_AGY_ROUTE="$(printf '%s' "$(agent $S_AGY_FAKE "$AGYTAG")" | env MODEL_POLICY_POLICY="$AGY_POLICY" sh "$RUN" "$GATE" 2>/dev/null)"
assert "SessionStart availability enables fake agy routing" agy \
  "$(printf '%s' "$FAKE_AGY_ROUTE" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).hookSpecificOutput.updatedInput.subagent_type)}catch{process.stdout.write("NOOP")}})')"
AGY_LOG="$SANDBOX/agy-argv.log"; BWRAP_LOG="$SANDBOX/bwrap-argv.log"
mkdir -p "$AGY_HOME/.gemini/antigravity-cli" "$AGY_HOME/.ssh" "$AGY_HOME/.gnupg"
printf '{}\n' > "$AGY_HOME/.gemini/antigravity-cli/settings.json"
printf '# gemini instructions\n' > "$AGY_HOME/.gemini/GEMINI.md"
FAKE_BWRAP="$SANDBOX/fake-bwrap"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$@" > "$BWRAP_ARGV_LOG"' 'AGY_BIN=""; while [ "$1" != -- ]; do if [ "$1" = "--ro-bind" ] && [ "${3:-}" = "/agy" ]; then AGY_BIN="$2"; fi; shift; done; shift; if [ "$1" = "/agy" ]; then shift; exec "$AGY_BIN" "$@"; fi; exec "$@"' > "$FAKE_BWRAP"
chmod +x "$FAKE_BWRAP"
"$NODE" -e 'const fs=require("fs");const p=JSON.parse(fs.readFileSync(process.argv[1]));p.agy.binary=process.argv[2];p.agy.sandbox.bwrap=process.argv[3];fs.writeFileSync(process.argv[4],JSON.stringify(p));' "$DIR/policy.json" "$FAKE_AGY" "$FAKE_BWRAP" "$AGY_POLICY"
mkdir -p "$SANDBOX/.worktrees/x" "$MODEL_POLICY_GRANTS"
git init -q "$SANDBOX/.worktrees/x"
grant() { "$NODE" -e 'const fs=require("fs"),path=require("path");const [d,id,pool,model,access,cwd,task]=process.argv.slice(1);fs.writeFileSync(path.join(d,id+".task"),task,{mode:0o600});fs.writeFileSync(path.join(d,id+".json"),JSON.stringify({pool,model,access,cwd,task_path:path.join(d,id+".task"),session_id:"s",created:new Date().toISOString(),expires:new Date(Date.now()+3600000).toISOString()})+"\n",{mode:0o600});' "$MODEL_POLICY_GRANTS" "$@"; }
agy_wrap_full() { env HOME="$AGY_HOME" MODEL_POLICY_POLICY="$AGY_POLICY" AGY_ARGV_LOG="$AGY_LOG" BWRAP_ARGV_LOG="$BWRAP_LOG" AGY_BIG_ANSWER="${AGY_BIG_ANSWER:-}" AGY_PLANT_NESTED="${AGY_PLANT_NESTED:-}" AGY_SYMLINK_TARGET="${AGY_SYMLINK_TARGET:-}" bash "$DIR/bin/agy-relay.sh" "$@" 2>&1; }
agy_wrap() { agy_wrap_full "$@" | sed -n '1p'; }
mkdir -p "$SANDBOX/.worktrees/x/.vscode" "$SANDBOX/.worktrees/x/.idea" "$SANDBOX/.worktrees/x/.github/workflows" "$SANDBOX/.worktrees/x/.husky"
printf 'host config\n' > "$SANDBOX/.worktrees/x/AGENTS.md"
G1=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
grant "$G1" thirdparty claude-sonnet-4-6 edit "$SANDBOX/.worktrees/x" 'review this'
out="$(agy_wrap --grant "$G1")"
assert "agy edit grant reaches the worker" yes "$(printf '%s' "$out" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).ok?"yes":"no")}catch{process.stdout.write("no")}})')"
assert "agy edit mode passes accept-edits" yes "$(grep -qx -- '--mode' "$AGY_LOG" && echo yes || echo no)"
assert "agy prompt tells headless workers not to use find" yes \
  "$(grep -Fq 'Do not use find (it is not allowed and aborts the run).' "$AGY_LOG" && echo yes || echo no)"
assert "edit grant binds captured cwd read-write at workspace" yes \
  "$("$NODE" -e 'const a=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n"),p=process.argv[2];process.stdout.write(a.some((x,i)=>x==="--bind"&&a[i+1]===p&&a[i+2]==="/workspace")?"yes":"no")' "$BWRAP_LOG" "$SANDBOX/.worktrees/x")"
assert "edit re-binds the top-level .git readonly" yes \
  "$("$NODE" -e 'const a=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n"),p=process.argv[2]+"/.git";process.stdout.write(a.some((x,i)=>x==="--ro-bind"&&a[i+1]===p&&a[i+2]==="/workspace/.git")?"yes":"no")' "$BWRAP_LOG" "$SANDBOX/.worktrees/x")"
assert "bwrap has private tmp before worktree bind" yes "$("$NODE" -e 'const a=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n");const t=a.findIndex((x,i)=>x==="--bind"&&a[i+2]==="/tmp"),w=a.findIndex((x,i)=>x==="--bind"&&a[i+2]==="/workspace");process.stdout.write(t>=0&&w>t?"yes":"no")' "$BWRAP_LOG")"
assert "edit mask tmpfses every configured directory" yes \
  "$("$NODE" -e 'const a=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n"),d=[".claude",".vscode",".idea",".github/workflows",".husky"];process.stdout.write(d.every(n=>a.some((x,i)=>x==="--tmpfs"&&a[i+1]==="/workspace/"+n))?"yes":"no")' "$BWRAP_LOG")"
assert "edit mask preserves existing files readonly and blocks absent files" yes \
  "$("$NODE" -e 'const a=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n"),w=process.argv[2];const existing=a.some((x,i)=>x==="--ro-bind"&&a[i+1]===w+"/AGENTS.md"&&a[i+2]==="/workspace/AGENTS.md"),absent=a.some((x,i)=>x==="--ro-bind"&&a[i+1]==="/dev/null"&&a[i+2]==="/workspace/.envrc");process.stdout.write(existing&&absent?"yes":"no")' "$BWRAP_LOG" "$SANDBOX/.worktrees/x")"
assert "used grant cannot be replayed" grant_already_used "$(agy_wrap --grant "$G1" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).reason)}catch{}})')"
G_BAD_GIT=abababababababababababababababababababababababab
mkdir -p "$SANDBOX/.worktrees/no-git"
grant "$G_BAD_GIT" thirdparty claude-sonnet-4-6 edit "$SANDBOX/.worktrees/no-git" 'bad git'
assert "edit grant without a top-level .git is refused" grant_invalid "$(agy_wrap --grant "$G_BAD_GIT" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).reason)}catch{}})')"
G_BAD_CWD=acacacacacacacacacacacacacacacacacacacacacacacac
grant "$G_BAD_CWD" thirdparty claude-sonnet-4-6 read-only "$AGY_HOME" 'bad cwd'
assert "wrapper refuses a secret-bearing cwd" cwd_not_allowed "$(agy_wrap --grant "$G_BAD_CWD" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).reason)}catch{}})')"
mkdir -p "$AGY_HOME/x"
G_ROOT=babababababababababababababababababababababababa
G_HOME_PARENT=cacacacacacacacacacacacacacacacacacacacacacacaca
G_HOME_X=dadadadadadadadadadadadadadadadadadadadadadadada
grant "$G_ROOT" thirdparty claude-sonnet-4-6 read-only / 'root cwd'
grant "$G_HOME_PARENT" thirdparty claude-sonnet-4-6 read-only /home 'shallow cwd'
grant "$G_HOME_X" thirdparty claude-sonnet-4-6 read-only "$AGY_HOME/x" 'descendant cwd'
assert "wrapper rejects / cwd" cwd_not_allowed "$(agy_wrap --grant "$G_ROOT" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).reason)}catch{}})')"
assert "wrapper rejects /home cwd" cwd_not_allowed "$(agy_wrap --grant "$G_HOME_PARENT" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).reason)}catch{}})')"
assert "wrapper permits $HOME/x cwd" true "$(agy_wrap --grant "$G_HOME_X" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(JSON.parse(s).ok))}catch{}})')"
G_NESTED=adadadadadadadadadadadadadadadadadadadadadadadad
grant "$G_NESTED" thirdparty claude-sonnet-4-6 edit "$SANDBOX/.worktrees/x" 'nested git'
out="$(AGY_PLANT_NESTED=1 agy_wrap --grant "$G_NESTED")"
assert "edit run reports a nested .git created during execution" nested_git_created "$(printf '%s' "$out" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).reason)}catch{}})')"
rm -rf "$SANDBOX/.worktrees/x/nested"
G_BIG=aeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeae
grant "$G_BIG" thirdparty claude-sonnet-4-6 read-only "$SANDBOX/.worktrees/x" 'big answer'
out="$(AGY_BIG_ANSWER=1 agy_wrap_full --grant "$G_BIG")"
assert "wrapper emits delimiter then a capped answer" yes "$(json="${out%%$'\n'*}"; state="$(printf '%s' "$json" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).truncated?"yes":"no")}catch{process.stdout.write("no")}})')"; case "$out" in *'--- AGY-ANSWER ---'*'truncated at 200 KiB'*) marker=yes ;; *) marker=no ;; esac; [ "$state" = yes ] && [ "$marker" = yes ] && echo yes || echo no)"
G2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
grant "$G2" gemini gemini-3.8-flash-medium edit "$SANDBOX/.worktrees/x" 'bad'
assert "forged Gemini edit grant is refused" grant_invalid "$(agy_wrap --grant "$G2" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).reason)}catch{}})')"
G3=cccccccccccccccccccccccccccccccccccccccccccccccc
grant "$G3" thirdparty claude-sonnet-4-6 read-only "$DIR" 'review'
MISSING_BWRAP_POLICY="$SANDBOX/agy-no-bwrap.json"
"$NODE" -e 'const fs=require("fs");const p=JSON.parse(fs.readFileSync(process.argv[1]));p.agy.sandbox.bwrap="/missing/bwrap";fs.writeFileSync(process.argv[2],JSON.stringify(p));' "$AGY_POLICY" "$MISSING_BWRAP_POLICY"
assert "missing bwrap refuses before launch" sandbox_unavailable "$(env MODEL_POLICY_POLICY="$MISSING_BWRAP_POLICY" MODEL_POLICY_GRANTS="$MODEL_POLICY_GRANTS" bash "$DIR/bin/agy-relay.sh" --grant "$G3" | sed -n '1p' | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).reason)}catch{}})')"

# Inspect the real wrapper argv.  The broad read-only root is intentionally
# overlaid by these mounts, so their order and read/write modes are security
# properties rather than cosmetic implementation details.
GIT_MAIN="$SANDBOX/agy-git-main"; GIT_WT="$SANDBOX/.worktrees/git-one"
git init -q "$GIT_MAIN"
git -C "$GIT_MAIN" config user.email test@example.invalid
git -C "$GIT_MAIN" config user.name test
printf 'tracked\n' > "$GIT_MAIN/tracked.txt"
git -C "$GIT_MAIN" add tracked.txt
git -C "$GIT_MAIN" commit -qm initial
git -C "$GIT_MAIN" worktree add -q "$GIT_WT" -b agy-test-worktree
GIT_COMMON="$(git -C "$GIT_WT" rev-parse --path-format=absolute --git-common-dir)"
G4=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
grant "$G4" thirdparty claude-sonnet-4-6 read-only "$GIT_WT" 'read only task'
out="$(agy_wrap --grant "$G4")"
assert "read-only grant reaches the worker" true "$(printf '%s' "$out" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(JSON.parse(s).ok))}catch{process.stdout.write("BADJSON")}})')"
assert "bwrap tmpfs-hides home before every home re-bind" yes \
  "$("$NODE" -e 'const a=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n"),h=process.argv[2];const home=a.findIndex((x,i)=>x==="--tmpfs"&&a[i+1]===h);let ok=home>=0;for(let i=0;i<a.length;i++)if((a[i]==="--bind"||a[i]==="--ro-bind")&&(a[i+1].startsWith(h+"/")||a[i+2].startsWith(h+"/")))ok&&=i>home;process.stdout.write(ok?"yes":"no")' "$BWRAP_LOG" "$AGY_HOME")"
assert "gemini base is readonly and only runtime state is writable" yes \
  "$("$NODE" -e 'const a=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n"),h=process.argv[2],g=h+"/.gemini",s=g+"/antigravity-cli";const ro=a.some((x,i)=>x==="--ro-bind"&&a[i+1]===g&&a[i+2]===g),bad=a.some((x,i)=>x==="--bind"&&a[i+1].startsWith(g)&&!a[i+1].startsWith(s+"/"));const run=["brain","conversations","cache","log","implicit","annotations","crashes","presence","history.jsonl","conversation_summaries.db","jetski_state.pbtxt","jetbox_summaries_proto.pb","last_check.timestamp"].every(n=>a.some((x,i)=>x==="--bind"&&a[i+1]===s+"/"+n));process.stdout.write(ro&&!bad&&run?"yes":"no")' "$BWRAP_LOG" "$AGY_HOME")"
assert "bwrap re-binds only agy runtime state under home" yes \
  "$("$NODE" -e 'const a=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n"),h=process.argv[2],bin=h+"/.local/bin/agy",g=h+"/.gemini",s=g+"/antigravity-cli";let ok=true;for(let i=0;i<a.length;i++)if(a[i]==="--bind"||a[i]==="--ro-bind")for(const p of [a[i+1],a[i+2]])if(p.startsWith(h+"/")&&p!==bin&&p!==g&&!p.startsWith(s+"/"))ok=false;process.stdout.write(ok?"yes":"no")' "$BWRAP_LOG" "$AGY_HOME")"
assert "read-only grant binds cwd read-only" yes \
  "$("$NODE" -e 'const a=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n"),p=process.argv[2];process.stdout.write(a.some((x,i)=>x==="--ro-bind"&&a[i+1]===p&&a[i+2]==="/workspace")?"yes":"no")' "$BWRAP_LOG" "$GIT_WT")"
assert "linked worktree common git dir is read-only bound" yes \
  "$("$NODE" -e 'const a=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n"),p=process.argv[2];process.stdout.write(a.some((x,i)=>x==="--ro-bind"&&a[i+1]===p&&a[i+2]===p)?"yes":"no")' "$BWRAP_LOG" "$GIT_COMMON")"
assert "read-only grant has no writable checkout bind" yes \
  "$("$NODE" -e 'const a=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n");process.stdout.write(a.some((x,i)=>x==="--bind"&&a[i+2]==="/workspace")?"no":"yes")' "$BWRAP_LOG")"
assert "bwrap never mounts /run and isolates IPC/process/session/UTS" yes \
  "$("$NODE" -e 'const a=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n"),opts=["--unshare-ipc","--unshare-pid","--new-session","--unshare-uts","--clearenv"];const run=a.some((x,i)=>(x==="--bind"||x==="--ro-bind")&&a[i+1]==="/run"&&a[i+2]==="/run");process.stdout.write(!run&&opts.every(x=>a.includes(x))?"yes":"no")' "$BWRAP_LOG")"
assert "bwrap keeps only the five approved environment variables" yes \
  "$("$NODE" -e 'const a=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n"),got=[];for(let i=0;i<a.length;i++)if(a[i]==="--setenv")got.push(a[i+1]);process.stdout.write(a.includes("--clearenv")&&got.sort().join(",")==="HOME,LANG,PATH,TERM,TZ"?"yes":"no")' "$BWRAP_LOG")"
RESOLV_TARGET_TEST="$(realpath /etc/resolv.conf 2>/dev/null || true)"
if [ -n "$RESOLV_TARGET_TEST" ] && [ -f "$RESOLV_TARGET_TEST" ]; then
  assert "DNS exposes only resolved resolv.conf file" yes \
    "$("$NODE" -e 'const a=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n"),p=process.argv[2];const own=a.some((x,i)=>x==="--ro-bind"&&a[i+1]===p&&a[i+2]===p),etc=a.some((x,i)=>x==="--ro-bind"&&a[i+1]===p&&a[i+2]==="/etc/resolv.conf");process.stdout.write(own&&etc?"yes":"no")' "$BWRAP_LOG" "$RESOLV_TARGET_TEST")"
fi

# A malicious worker used to replace /relay/answer.md with this symlink, which
# the wrapper reopened by name. The relay now has task input only and stdout is
# already held by the supervisor, so the host secret must never be relayed.
SECRET_TARGET="$SANDBOX/relay-secret"; printf 'DO-NOT-EXFILTRATE\n' > "$SECRET_TARGET"
G_SYMLINK=edededededededededededededededededededededededed
grant "$G_SYMLINK" thirdparty claude-sonnet-4-6 read-only "$GIT_WT" 'symlink sabotage'
out="$(AGY_SYMLINK_TARGET="$SECRET_TARGET" agy_wrap_full --grant "$G_SYMLINK")"
assert "relay symlink sabotage cannot exfiltrate host content" no \
  "$(printf '%s' "$out" | grep -q 'DO-NOT-EXFILTRATE' && echo yes || echo no)"
assert "relay mounts only a readonly task, never writable output" yes \
  "$("$NODE" -e 'const a=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n");const task=a.some((x,i)=>x==="--ro-bind"&&a[i+2]==="/relay/task.md"),relay=a.some((x,i)=>x==="--bind"&&a[i+2]==="/relay");process.stdout.write(task&&!relay?"yes":"no")' "$BWRAP_LOG")"

DENY_AGY="$SANDBOX/permission-denied-agy"
printf '%s\n' '#!/usr/bin/env bash' 'printf "jetski: no output produced: \\\"read_file\\\" permission denied\n" >&2' > "$DENY_AGY"
chmod +x "$DENY_AGY"
DENY_POLICY="$SANDBOX/permission-denied-policy.json"
"$NODE" -e 'const fs=require("fs");const p=JSON.parse(fs.readFileSync(process.argv[1]));p.agy.binary=process.argv[2];fs.writeFileSync(process.argv[3],JSON.stringify(p))' "$AGY_POLICY" "$DENY_AGY" "$DENY_POLICY"
G8=565656565656565656565656565656565656565656565656
grant "$G8" thirdparty claude-sonnet-4-6 read-only "$DIR" 'permission denied task'
out="$(env HOME="$AGY_HOME" MODEL_POLICY_POLICY="$DENY_POLICY" AGY_ARGV_LOG="$AGY_LOG" BWRAP_ARGV_LOG="$BWRAP_LOG" bash "$DIR/bin/agy-relay.sh" --grant "$G8" 2>&1 | sed -n '1p')"
assert "quoted agy permission denial names the permission" agy_permission_denied:read_file "$(printf '%s' "$out" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).reason)}catch{process.stdout.write("BADJSON")}})')"

G5=ffffffffffffffffffffffffffffffffffffffffffffffff
grant "$G5" thirdparty claude-sonnet-4-6 read-only "$DIR" 'expired task'
"$NODE" -e 'const fs=require("fs");const p=process.argv[1],g=require(p);g.expires="2000-01-01T00:00:00.000Z";fs.writeFileSync(p,JSON.stringify(g))' "$MODEL_POLICY_GRANTS/$G5.json"
out="$(agy_wrap --grant "$G5")"; status=$?
assert "expired grant is refused" grant_expired "$(printf '%s' "$out" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).reason)}catch{}})')"
assert "expired false result has a nonzero exit" yes "$([ "$status" -ne 0 ] && echo yes || echo no)"
MISSING_ID=111111111111111111111111111111111111111111111111
assert "missing grant is refused" grant_missing "$(agy_wrap --grant "$MISSING_ID" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).reason)}catch{}})')"
assert "grant id path characters are rejected" invalid_grant_id "$(agy_wrap --grant '../not-a-grant' | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).reason)}catch{}})')"

# The task crosses the relay boundary as a private file, never as one enormous
# argv element.  A >200 KiB grant must therefore behave exactly like a normal one.
G6=121212121212121212121212121212121212121212121212
"$NODE" -e 'const fs=require("fs"),path=require("path");const[d,id,cwd]=process.argv.slice(1),task=path.join(d,id+".task");fs.writeFileSync(task,"x".repeat(210*1024),{mode:0o600});fs.writeFileSync(path.join(d,id+".json"),JSON.stringify({pool:"thirdparty",model:"claude-sonnet-4-6",access:"read-only",cwd,task_path:task,session_id:"s",created:new Date().toISOString(),expires:new Date(Date.now()+3600000).toISOString()}))' "$MODEL_POLICY_GRANTS" "$G6" "$DIR"
out="$(agy_wrap --grant "$G6")"; status=$?
assert "large agy task is file-backed, not one argv string" true "$(printf '%s' "$out" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(JSON.parse(s).ok))}catch{process.stdout.write("BADJSON")}})')"
assert "ok:true wrapper result exits zero" 0 "$status"

QUOTE_AGY="$SANDBOX/quote-jetski-agy"; printf '%s\n' '#!/usr/bin/env bash' 'printf "answer quotes: jetski: no output produced\\n"' > "$QUOTE_AGY"; chmod +x "$QUOTE_AGY"
QUOTE_POLICY="$SANDBOX/quote-jetski-policy.json"
"$NODE" -e 'const fs=require("fs");const p=JSON.parse(fs.readFileSync(process.argv[1]));p.agy.binary=process.argv[2];fs.writeFileSync(process.argv[3],JSON.stringify(p))' "$AGY_POLICY" "$QUOTE_AGY" "$QUOTE_POLICY"
G7=343434343434343434343434343434343434343434343434
grant "$G7" thirdparty claude-sonnet-4-6 read-only "$DIR" 'quoted jetski'
out="$(env HOME="$AGY_HOME" MODEL_POLICY_POLICY="$QUOTE_POLICY" BWRAP_ARGV_LOG="$BWRAP_LOG" bash "$DIR/bin/agy-relay.sh" --grant "$G7" 2>&1 | sed -n '1p')"; status=$?
assert "a worker answer quoting jetski remains ok" true "$(printf '%s' "$out" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(JSON.parse(s).ok))}catch{process.stdout.write("BADJSON")}})')"
assert "quoted jetski ok result exits zero" 0 "$status"

SNAP_OUT="$SANDBOX/snapshot.json"
printf '%s' '{"rate_limits":{"five_hour":{"used_percentage":81}}}' | MODEL_POLICY_USAGE_SNAPSHOT="$SNAP_OUT" bash "$DIR/bin/usage-snapshot.sh"
assert "usage snapshot helper stays silent" "" "$(printf '%s' '{"rate_limits":{}}' | MODEL_POLICY_USAGE_SNAPSHOT="$SNAP_OUT" bash "$DIR/bin/usage-snapshot.sh")"
assert "usage snapshot helper writes rate-limit data" 81 \
  "$("$NODE" -e 'const p=require(process.argv[1]);process.stdout.write(String(p.five_hour_pct))' "$SNAP_OUT" 2>/dev/null)"

rm -f "$SESS/$S_AGY.json" "$SESS/$S_AGY.events" "$SESS/$S_AGY_OLD.json" "$SESS/$S_AGY_OLD.events" \
  "$SESS/$S_AGY_MISSING.json" "$SESS/$S_AGY_MISSING.events" "$SESS/$S_AGY_FAKE.json" "$SESS/$S_AGY_FAKE.events"
rm -f "$SESS/$S_CX.json" "$SESS/$S_CX.events"
rm -f "$SESS/$SESSION_OK.json" "$SESS/$SESSION_READY.json" "$SESS/$SESSION_LEGACY.json"
echo
echo "-----------------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
