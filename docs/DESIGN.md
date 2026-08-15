# Design

Why this is built the way it is, and what was tried and rejected. Measurements come from
one developer's three machines over normal work; treat them as one honest data point, not
a benchmark.

## The problem

Claude Code resolves a subagent's model in this order:

```
CLAUDE_CODE_SUBAGENT_MODEL env var
  -> per-invocation `model` parameter
    -> agent definition frontmatter
      -> the main conversation's model
```

In practice nothing sets the middle layers, so almost every subagent lands on the last
one. A survey of 2,001 transcripts found `model` specified on **0 of 66** `Agent` calls
and **19 of 205** `Workflow` calls. Read-only file searches were running on the same
premium model as the main conversation, at the session's effort setting.

The cost ladder, using Anthropic's published rates as relative weights:

| Tier | Input | Output | Relative |
|---|---|---|---|
| haiku | $1/M | $5/M | 1× |
| sonnet | $3/M | $15/M | 3× |
| opus | $5/M | $25/M | 5× |
| fable | $10/M | $50/M | 10× |

## Architecture

Three hooks over one shared library.

| Hook | Event | Job |
|---|---|---|
| `brief.mjs` | `SessionStart` | Record the session model and which agents exist; brief the model on the tiers |
| `gate.mjs` | `PreToolUse` (`Agent\|Workflow`) | Set the model on spawns; rewrite Workflow scripts |
| `log.mjs` | `SubagentStop` | Record real usage, outcome, and the model that actually ran |

Everything tunable is in `policy.json` so the code does not need editing to retune.

### Tier resolution

```
explicit [cheap]/[hard] tag        (authoritative — bypasses the clamps below)
  -> agentTypes table
  -> catch-all prompt scoring
  -> clamp to the agent definition's declared model
  -> clamp to the explicitly requested model
  -> clamp to the session model
  -> clamp to a tier this account can actually run
```

Every step after scoring is a **clamp**, never a promotion. This is deliberate: the whole
point is to reduce cost, and a policy that can raise it is worse than no policy. The
session clamp specifically protects configs whose session model is already cheap — without
it, routing a `Plan` agent to opus inside a sonnet session would *increase* spend.

### Why cost per completed task, not cost per spawn

A haiku agent that gives up and forces an opus retry costs more than opus would have. So
`log.mjs` records a `looks_failed` signal from the agent's closing message, and the tuning
skill uses it to find downgrades that backfired. Optimising the cheaper metric would
reward exactly the wrong behaviour.

## Workflow enforcement

`agent()` calls inside a Workflow script never pass through the `Agent` tool, so
`PreToolUse` has nothing to intercept — and that path carried the large majority of all
subagent volume in the measured sample. Advising the model to tier its own scripts worked
only sometimes.

So the script is **rewritten** before it runs:

1. Mask comments and string literals (offset-preserving, so indices map back to the source).
2. Find the end of the mandatory `export const meta = {...}` literal by brace matching.
3. Rewrite real `agent(` call sites to `__mpAgent(`, excluding `foo.agent(` and identifier suffixes.
4. Inject a shim carrying the tier table, pattern lists, effort map, session ceiling and
   disabled tiers, all inlined as JSON.
5. Syntax-check with `new Function`. On any failure, return nothing and let the original run.

### Why the shim scores at runtime

Scoring needs the prompt text, and at the call site the prompt is usually a template
literal or a variable:

```js
await parallel(FILES.map(f => () => agent(`review ${f}`)))
```

That is one call site and N spawns. Static analysis cannot recover those strings, but the
shim runs *inside* the workflow and sees each fully interpolated prompt. Verified live: a
fan-out scored each item on its own prompt, not on the template.

### Indirect invocations

`{scriptPath}` and `{name}` carry a reference, not source. The file is **read** and the
rewritten source is passed inline, with `scriptPath`/`name` deleted from the input — they
take precedence over `script`, so leaving either in place makes the rewrite inert. The
file on disk is never modified.

Three cases skip deliberately:

| case | why |
|---|---|
| source already contains the shim | an inline script is rewritten *before* Claude Code persists it, so an iterate-on-`scriptPath` loop already carries it; re-injecting would nest it |
| `resumeFromRunId` present | resume replays agents whose `(prompt, opts)` match; adding a model changes `opts` and discards work already paid for |
| unresolvable | a built-in name, or a path that cannot be read |

## Tried and rejected

### Patching `globalThis.agent` to reach nested workflows

A `workflow()` call inside a script runs a child whose source the gate never sees. A probe
found `agent` is a **writable function property on `globalThis`**, so the shim wrapped
`workflow()` to patch it for the child's duration and restore it afterwards. Unit tests
passed.

The live test did not:

| agent | model |
|---|---|
| parent's own | haiku |
| child's, via `workflow()` | **opus** |

Both prompts were equally mechanical. The child resolves its own `agent` binding and never
reads the global, so the patch was inert. It was reverted rather than shipped — code that
mutates a host runtime global for no measured effect is worse than a documented gap,
especially since it would have *looked* like a fix in every artefact.

The gate now counts `workflow(` sites and warns. Closing it properly would mean resolving
a literal `scriptPath` at gate time, rewriting the child, caching it, and repointing the
parent — feasible, but new machinery for a construct that appeared **zero** times in 202
persisted scripts. If your ledger shows `nested > 0`, the tuning skill will say so.

### Automatic promotion to the top tier

`fable` is 10× haiku and 2× opus. Auto-promoting into it fights the goal, so it is
reachable only via an explicit `[hard]` tag.

## Hard-won details

**`updatedInput` requires `permissionDecision: "allow"`.** Returning a rewritten input
alone is silently ignored. A test spawn logged `set: haiku` while running on
`claude-opus-5`, and the entire unit suite passed — because the tests only asserted on what
the hook *emitted*, never on what the harness *did*. The ledger now records `actual_model`
read back from the subagent's transcript, which is the only field that can prove
enforcement. Adding `allow` does not create a blanket approver: deny and ask rules are
still evaluated regardless of what a hook returns.

**A per-invocation model overrides agent frontmatter.** `worker` declares `model: sonnet`,
but an emitted `model: opus` wins. Measured: 108 of 112 real spawns were `worker`, and
prompt scoring promoted every one to opus — the tier system inverted for the agent built
to be the cheap mid tier. A declared model is now a ceiling.

**Prompt length barely correlates with complexity.** A 1,500-character threshold promoted
to opus; the median real prompt was 2,692 characters. "Long" was a constant, not a signal,
and the sonnet default was reached once in 112 spawns.

**Fan-out is undercounted by literal call sites.** `parallel(FILES.map(f => () =>
agent(...)))` is one literal `agent(` and N spawns. Any heuristic counting occurrences
must treat `parallel`/`pipeline` containing an `agent()` as fan-out regardless of count.

**Prose is not code.** An early fan-out detector matched the word "parallel" inside
comments and prompt strings and denied valid scripts — worse than missing an optimisation.
Hence the masking pass.

**Test suites must not write to production data.** An early `test.sh` carried the comment
"isolate test writes from the real ledger" and an env var nothing read, then `rm -f`'d the
live ledger — destroying 267 rows of accumulated evidence. Isolation is now via
`MODEL_POLICY_LEDGER` / `MODEL_POLICY_SESSIONS` pointing at a `mktemp -d` sandbox, and
verified by checksumming the real file around the run.

**nvm's node is invisible to hooks.** nvm only populates `PATH` in interactive shells, so
`#!/usr/bin/env node` can silently never fire. `hooks/run.sh` resolves node explicitly and
exits 0 if it finds none, so a missing runtime degrades to "no policy" rather than a
broken tool call.

**Reading a subagent transcript can OOM fatally.** `readFileSync` on a very large
transcript raises a V8 heap error that is *not* catchable, so `try/catch` cannot preserve
fail-open. `log.mjs` caps at 16 MB and reads head+tail beyond that, flagging totals as
partial.

## Fail-open contract

Every hook, on any error, must exit 0 with no stdout so the tool call proceeds exactly as
if the hook were absent. Specific guards:

- Invalid `policy.json` → behave as if uninstalled
- A resolved tier not in `tierOrder` (a config typo) → log an error row, emit nothing
- Missing or malformed `tool_input` → touch nothing (an early version emitted a stub that
  would have replaced the whole input and destroyed the prompt)
- A script rewrite that does not parse → discard it, run the original
- No usable node → exit 0
