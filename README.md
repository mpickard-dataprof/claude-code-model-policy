# claude-code-model-policy

**Every Claude Code subagent inherits your main session's model.** A subagent that only
greps for a filename runs on the same expensive model as your conversation — and you pay
for it, every time, on every fan-out.

This is a set of Claude Code hooks that pick an appropriate model for each subagent
automatically, based on what the subagent was actually asked to do.

A survey of 2,001 transcripts on the author's machines before installing this found:

| spawn path | total | with a model set |
|---|---|---|
| `Agent` tool | 66 | **0** |
| `Workflow` scripts | 205 | 19 |

Every one of the rest ran on the session model. On one machine, 304 workflow subagents had
run on the most expensive tier available — not because anyone chose that, but because
nobody chose anything.

---

## What it does

**1. Sets a model on every `Agent` spawn.**
A fixed table for known agent types, then prompt scoring for generic ones:

```
Explore, statusline-setup     -> haiku
claude-code-guide            -> sonnet
Plan                         -> opus
general-purpose / claude     -> scored from the prompt (base: sonnet)
```

**2. Rewrites `Workflow` scripts so their `agent()` calls are tiered too.**
This matters more than it sounds: `agent()` calls inside a workflow never pass through
the `Agent` tool, so a hook cannot intercept them. Instead the script is rewritten before
it runs, injecting a shim that scores each prompt **at runtime** — which means the
idiomatic fan-out works correctly:

```js
await parallel(FILES.map(f => () => agent(`review ${f}`)))
```

That is one call site and N spawns, and each spawn is scored on its own interpolated
prompt. No static analysis of the script could recover those strings.

**3. Sets effort, not just model.** `effort` cannot be passed per invocation through the
`Agent` tool (its schema rejects unknown fields), so two agent definitions — `scout`
(haiku + `effort: low`) and `worker` (sonnet + `effort: medium`) — carry model and effort
together, and mechanical spawns are redirected to them. Inside a Workflow, `opts.effort`
is settable directly and the shim sets it.

**4. Records what actually happened.** Every routing decision and every completion goes to
a JSONL ledger, including `actual_model` read back from each subagent's own transcript.
That last field exists because an earlier version of this logged `set: haiku` while the
agent really ran on Opus — see [Gotchas](#gotchas).

## What it never does

- **Never raises cost.** Every rule is a clamp. A tier is capped by the model you
  explicitly requested, by the agent definition's own declared model, and by your session
  model — whichever is cheapest wins.
- **Never overrides an explicit choice.** `agent(prompt, { model: 'opus' })` is left
  exactly as written.
- **Never breaks a tool call.** Every hook is fail-open by contract: on any error it exits
  0 with no output and the call proceeds as if the hook were absent. A script rewrite is
  discarded unless it passes a syntax check first.

---

## Install

Requires **Node 18+**, Python 3 (for the checker), bash, and Claude Code.

```bash
git clone https://github.com/mpickard-dataprof/claude-code-model-policy.git
cd claude-code-model-policy
bash install.sh
```

The installer finds every Claude Code config dir (`~/.claude*`, plus `$CLAUDE_CONFIG_DIR`
if set), merges the hooks into each `settings.json` — preserving any hooks you already
have — backs up what it touches, and links the `scout`/`worker` agents and the tuning
skill. It is idempotent; re-run it after `git pull`.

Then **restart any running Claude Code session**, or see [Activating without a
restart](#activating-without-a-restart).

### Verify it actually works

```bash
python3 deploy-check.py
```

This runs every code path — the declared-model ceiling, the scout redirect, inline script
rewriting, `scriptPath` read-back, resume preservation, the nested-workflow warning —
against a throwaway ledger, touching no real state. Files being present proves nothing; a
hook can be installed and inert.

### Uninstall

```bash
bash uninstall.sh --dry-run   # show what would change
bash uninstall.sh             # remove hooks and links; your settings survive
```

Removes only *this* install's registrations, leaves any hooks you added yourself, and
never deletes a file you wrote — a hand-written `scout.md` survives untouched.

---

## Using it

### Tags

Put a tag in the Agent task description to force a tier:

```
[cheap]   -> haiku   (bypasses the clamps; a deliberate cost decision)
[hard]    -> the top tier
```

### Seeing what it did

```bash
./verify.sh 7        # last 7 days
```

```
last 7d: 112 Agent spawns routed, 150 completed, 6 workflows checked

tier CHOSEN by the policy:
   sonnet  110
   opus      2

model ACTUALLY run (ground truth):
   claude-sonnet-5            108
   claude-haiku-4-5-20251001    4

Workflow enforcement: 6/6 scripts rewritten (23 agent() call sites tiered)
```

### Tuning it

After ~30 spawns of real work, run `/model-policy-tune` in Claude Code. It joins routing
decisions to outcomes, reports realised savings against a counterfactual, and proposes
`policy.json` edits with the evidence for each. It optimises **cost per completed task,
not cost per spawn** — a haiku agent that gives up and forces an opus retry costs more
than opus would have, so the ledger records a `looks_failed` signal to catch downgrades
that backfired.

It will decline to recommend changes on a small sample rather than tune on noise.

---

## Configuration

Everything tunable lives in `policy.json` — edit that, not the hook code.

| Key | What it controls |
|---|---|
| `tierOrder` | The cost ladder, cheapest first |
| `disabledTiers` | Tiers your account cannot use (see below) |
| `agentTypes` | Fixed tier per agent type |
| `catchAll` | Prompt scoring: keyword lists and length thresholds |
| `overrides` | The `[cheap]` / `[hard]` tags |
| `redirect` | Which tiers redirect to `scout` / `worker` |
| `workflow.enforce` | Set `false` to advise instead of rewriting |
| `workflow.effortByTier` | Effort paired with each tier |

### If you don't have access to every tier

`fable` requires specific access. Routing to a model you cannot run fails the spawn, so
any tier in `disabledTiers` falls back to the next cheaper one and the ledger records the
substitution as `+unavailable:fable->opus`.

`install.sh` pre-fills this by scanning your transcripts for models you have actually
used. That is evidence, not proof — absence of a model in your history does not prove you
lack access — so check it and edit if wrong:

```json
"disabledTiers": ["fable"]
```

### Activating without a restart

Hooks are registered as *commands*, and Claude Code spawns them fresh on every tool call.
So edits to the hooks or to `policy.json` take effect on the next call with no restart.

Two things do **not** hot-reload:

- **Registering a hook for the first time** — a session that started before `install.sh`
  ran has no hook registered, so nothing fires. That needs a new session.
- **Agent definitions.** `scout` and `worker` are read once at session start. The gate
  therefore refuses to redirect to them unless it can prove the session loaded them —
  otherwise the spawn dies with `Agent type 'scout' not found`. Model tiering still
  applies in such a session; effort tiering starts with the next one.

---

## Gotchas

Things that cost real debugging time, recorded so they cost you none.

**`updatedInput` is silently ignored without `permissionDecision: "allow"`.** A hook can
return a rewritten input, log it confidently, and have Claude Code discard it. A test
spawn logged `set: haiku` while running on `claude-opus-5`, and every unit test passed —
because the tests only checked what the hook *emitted*, never what the harness *did* with
it. This is why the ledger now records `actual_model` from the transcript. Adding `allow`
does not make the hook a blanket approver: per the hooks reference, deny and ask rules are
still evaluated regardless of what a hook returns.

**A per-invocation model beats agent frontmatter.** `worker` declares `model: sonnet`, but
an emitted `model: opus` wins. In one measured run, 108 of 112 spawns were `worker` and
prompt scoring promoted every one to Opus — the tier system inverted for the exact agent
built to be the cheap mid tier. An agent's declared model is now treated as a ceiling.

**Prompt length is a terrible complexity signal.** An earlier threshold promoted any
prompt over 1,500 characters to Opus. The median real prompt measured 2,692 characters, so
"long" was a constant, not a signal, and the sonnet default was reached once in 112 spawns.

**Nested `workflow()` calls are not covered.** A child workflow's script never reaches the
gate. `agent` *is* a writable property on `globalThis`, so patching it for the child's
duration looks like a fix — it is not. Measured: the child still ran on Opus while the
parent's equivalent prompt ran on haiku, because the child resolves its own binding. The
gate counts these and warns instead. See [docs/DESIGN.md](docs/DESIGN.md).

**nvm's node is invisible to hooks.** nvm only populates `PATH` in interactive shells, so
`#!/usr/bin/env node` can silently never run. All hooks go through `hooks/run.sh`, which
resolves node explicitly.

---

## How it fits together

```
hooks/
  run.sh      launcher; resolves node explicitly
  brief.mjs   SessionStart  — record session model, brief Claude on the tiers
  gate.mjs    PreToolUse    — set the model on Agent spawns; rewrite Workflow scripts
  log.mjs     SubagentStop  — record real token usage, outcome, and actual model
  lib.mjs     tier resolution, clamps, script rewriting, ledger
agents/       scout.md, worker.md — model + effort together
skill/        the /model-policy-tune analysis skill
```

Design rationale, measurements, and the full list of things that were tried and rejected:
**[docs/DESIGN.md](docs/DESIGN.md)**.

## Testing

```bash
bash test.sh          # 72 assertions
python3 deploy-check.py
```

CI runs the suite on Ubuntu and macOS across Node 18/20/22.

## Contributing

Issues and PRs welcome. Two rules that this project takes seriously:

1. **A green unit suite proves only that a hook emitted well-formed JSON.** If a change
   affects what Claude Code actually does, verify it with a real spawn and say so.
2. **Fail open.** No change may make a hook capable of breaking a tool call.

## License

MIT — see [LICENSE](LICENSE).
