#!/usr/bin/env python3
# Deployment check: verifies the hooks are registered AND behave correctly on this
# machine. Files being present proves nothing — a hook can be installed and inert.
# Runs every code path against a throwaway ledger; touches no real state.
#   python3 <install-dir>/deploy-check.py
import json, os, subprocess, sys, tempfile
home = os.path.expanduser("~")
# Resolve the install root from this file, so the check works wherever it was
# installed rather than only at one hardcoded path.
R = os.path.dirname(os.path.abspath(__file__))
RUN, GATE = os.path.join(R, "hooks/run.sh"), os.path.join(R, "hooks/gate.mjs")
sandbox = tempfile.mkdtemp(prefix="mp-probe.")
env = dict(os.environ, MODEL_POLICY_LEDGER=os.path.join(sandbox, "l.jsonl"),
           MODEL_POLICY_SESSIONS=os.path.join(sandbox, "s"))
META = 'export const meta = { name: "p", description: "d", phases: [{title:"P"}] }'
child = os.path.join(sandbox, "child.js")
open(child, "w").write(META + '\nconst r = await agent("count things");\n')
# The scout redirect is guarded: it only fires when SessionStart ran for this session
# AND recorded the agent as present on disk. Without this record the guard correctly
# refuses, so a probe lacking it measures the guard, not the redirect.
os.makedirs(env["MODEL_POLICY_SESSIONS"], exist_ok=True)
open(os.path.join(env["MODEL_POLICY_SESSIONS"], "probe.json"), "w").write(
    json.dumps({"model": "opus", "at": "2099-01-01T00:00:00.000Z",
                "via": "sessionstart", "agents": ["scout", "worker"]}))

def gate(ti):
    p = subprocess.run(["sh", RUN, GATE], input=json.dumps(
        {"session_id": "probe", "tool_use_id": "t", "hook_event_name": "PreToolUse",
         "tool_name": ti.pop("_tool"), "tool_input": ti}),
        capture_output=True, text=True, env=env)
    if p.returncode != 0: return {"__exit": p.returncode, "__err": p.stderr[:200]}
    return json.loads(p.stdout)["hookSpecificOutput"] if p.stdout.strip() else {}

fails = []
def check(label, got, want):
    good = got == want
    if not good: fails.append(label)
    print(f"  {'PASS' if good else 'FAIL'}  {label:44} -> {got}" + ("" if good else f"  WANT {want}"))

r = gate({"_tool": "Agent", "subagent_type": "worker", "description": "d", "prompt": "implement the parser " + "x"*3000})
check("worker clamped to its declared sonnet", r.get("updatedInput", {}).get("model"), "sonnet")
r = gate({"_tool": "Agent", "subagent_type": "general-purpose", "description": "d", "prompt": "find which file defines auth"})
check("mechanical redirects to scout", r.get("updatedInput", {}).get("subagent_type"), "scout")
r = gate({"_tool": "Workflow", "script": META + '\nawait parallel(F.map(f => () => agent("audit " + f)));'})
check("inline workflow rewritten", "__mpAgent" in r.get("updatedInput", {}).get("script", ""), True)
r = gate({"_tool": "Workflow", "scriptPath": child})
check("scriptPath read back and rewritten", "__mpAgent" in r.get("updatedInput", {}).get("script", ""), True)
check("scriptPath dropped from input", "scriptPath" in r.get("updatedInput", {}), False)
check("child file NOT modified on disk", "__mpAgent" in open(child).read(), False)
r = gate({"_tool": "Workflow", "scriptPath": child, "resumeFromRunId": "wf_x"})
check("resume left alone (cache preserved)", r, {})
r = gate({"_tool": "Workflow", "script": META + '\nawait agent("go");\nawait workflow({scriptPath:"/tmp/c.js"});'})
check("nested workflow() warned about", "nested workflow" in r.get("permissionDecisionReason", ""), True)
check("nested workflow() NOT rewritten", "__mpWorkflow" in r.get("updatedInput", {}).get("script", ""), False)
r = gate({"_tool": "Bash", "command": "ls"})
check("unrelated tool ignored", r, {})

rows = [json.loads(l) for l in open(env["MODEL_POLICY_LEDGER"]) if l.strip()]
check("nested count logged for the tuner", max((x.get("nested", 0) for x in rows if x.get("event") == "workflow"), default=None), 1)
check("actual_model field present in log.mjs", "actual_model" in open(os.path.join(R, "hooks/log.mjs")).read(), True)
subprocess.run(["rm", "-rf", sandbox])
print(f"  -> {'ALL PASS' if not fails else 'FAILURES: ' + ', '.join(fails)}")
sys.exit(0 if not fails else 1)
