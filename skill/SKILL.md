---
name: model-policy-tune
description: Analyse the subagent model-routing ledger and propose tuned rules. Use when the user wants to review, tune, or audit tiered subagent model selection, asks how much the model policy is saving, or asks whether any agents are being routed to a model that is too cheap or too expensive.
---

# Tune the subagent model policy

Analyse the routing ledger plus subagent transcripts, then propose concrete edits to
`policy.json`.

## Locating the install

This skill is symlinked into each config dir, so it cannot assume an install path. Resolve the
root from the registered hook command — that is authoritative because it is what Claude Code
actually executes:

```bash
ROOT="$(python3 - <<'EOF'
import json, glob, os
for f in glob.glob(os.path.expanduser("~/.claude*/settings.json")):
    try: s = json.load(open(f))
    except Exception: continue
    for arr in (s.get("hooks") or {}).values():
        for m in arr:
            for h in m.get("hooks", []):
                c = h.get("command", "")
                if "model-policy" in c and "gate.mjs" in c:
                    for tok in c.replace('"', " ").split():
                        if tok.endswith("gate.mjs"):
                            print(os.path.dirname(os.path.dirname(tok))); raise SystemExit
EOF
)"
```

The ledger is `$ROOT/ledger.jsonl` and the policy is `$ROOT/policy.json`. If that resolves to
nothing, the hooks are not installed — say so and stop rather than analysing an empty file.

**Optimise cost per _completed_ task, not cost per spawn.** A haiku agent that gives up and
forces an opus retry costs more than routing to opus in the first place. A rule is only a good
downgrade if its agents finish successfully.

**Propose, do not apply.** Show a diff and wait for approval before editing `policy.json`.

## Procedure

### 1. Load the data

Use context-mode (`ctx_execute`) so raw ledger contents stay out of the conversation — only the
computed answer comes back.

- Ledger: `$ROOT/ledger.jsonl`, one JSON object per line.
  - `event: "route"` — an Agent-tool routing decision (`agent_type`, `rule`, `set`, `requested`,
    `session_tier`, `prompt_chars`, `redirect_to`)
  - `event: "complete"` — an outcome (`agent_type`, `usage`, `looks_failed`, `tail`,
    **`actual_model`** — the model read back from the agent's own transcript)
  - `event: "workflow"` — a Workflow call (`form`, `enforced`, `sites`, `nested`, `reason`,
    `agent_calls`, `model_opts`, `denied`)

**`actual_model` is ground truth; `set` is only an intention.** A hook once logged `set: haiku`
while the agent ran on opus. Wherever both exist, report any disagreement between them
prominently — that is a broken enforcement path, and it outranks every tuning question below.

**There are two populations, and only one of them pairs.**

- *Agent-tool spawns* have both a `route` and a `complete` row. Join them on **`prompt_fp`**
  (a normalised prompt fingerprint written by both hooks), scoped to `session_id`. Do **not**
  pair by arrival order: agents run in parallel during fan-out, so order-based pairing silently
  mismatches rows.
- *Workflow subagents* (`agent_type: "workflow-subagent"`) never pass through the Agent gate, so
  they have a `complete` row and **no `route` row, by design**. They are typically the majority of
  all spend. Do **not** drop them as unpaired — analyse them as their own population, keyed on
  `actual_model` and `usage`. Their tier was chosen by the injected shim, so `actual_model` is the
  only record of what the policy decided.

Report the size of each population separately. Only genuinely unmatched Agent-tool rows count as
a drop worth worrying about; a high drop rate *there* means fingerprints are not lining up and
every downstream number is suspect.
- `event: "error"` rows mean the policy produced a tier outside `tierOrder` — a config typo. Report
  these first; routing was skipped entirely for those spawns.
- If a ledger from another machine is available, accept multiple paths and pool them.

State the sample size up front. **Under ~30 paired spawns, report findings but recommend no
changes yet** — say so plainly rather than tuning on noise.

### 2. Report realised savings

Price per million tokens (relative weight in brackets):

| Tier | Input | Output | Relative |
|---|---|---|---|
| haiku | $1 | $5 | 1x |
| sonnet | $3 | $15 | 3x |
| opus | $5 | $25 | 5x |
| fable | $10 | $50 | 10x |

Price actual spend by **`actual_model`**, not by `set` — `set` is what the hook asked for, and the
two have diverged before. Then the counterfactual: the same token counts priced at each spawn's
`session_tier`, which is what would have happened with no policy. Report both and the delta.

Cover both populations. Workflow subagents have no `session_tier` field of their own, so take it
from any `route` row in the same `session_id`, or from the `workflow` row's session; where neither
exists, exclude them from the counterfactual and say how many were excluded.

Caveat this honestly — token counts differ between models for the same work, so the
counterfactual is an estimate, not a measurement.

### 3. Per-rule statistics

One row per distinct `rule` value (`table:Explore`, `score:mechanical`, `tag:hard`, ...):

| Rule | Fires | Tier | Median output tokens | Median turns | `looks_failed` rate |

### 4. Find mis-routed rules

**Upgrade candidates** — cheapness costing more than it saves:
- `looks_failed` rate materially above the corpus average
- Retry pattern: a spawn whose prompt closely matches an earlier spawn in the same session
  within a few minutes, especially where the first was routed cheaper
- Turn counts well above the corpus median (the agent is grinding)

**Downgrade candidates** — headroom:
- Consistently low `looks_failed`, low turn counts, low output tokens for their tier
- Especially `score:base` (the sonnet default) spawns that look mechanical in hindsight

### 5. Vocabulary drift

List `score:base` prompts — the ones that matched neither keyword list. These are where the
Layer 2 patterns are blind. Quote a few verbatim and propose additions to `catchAll.cheap.patterns`
or `catchAll.expensive.patterns` drawn from the actual phrasing, not invented wording.

Also check `score:mechanical` spawns with a high `looks_failed` rate: a cheap-list pattern may be
matching work that is not actually mechanical.

### 6. Workflow enforcement coverage

Workflow scripts are rewritten, not merely advised: `injectWorkflowTiers` injects a shim that
tiers every `agent()` call which set no model of its own. From `event: "workflow"` rows report:

- **Coverage** — `enforced: true` as a share of all rows, and total `sites` tiered.
- **Escapes** — rows with `enforced: false`, grouped by `reason`. Each has a distinct meaning:
  - `already-enforced` / `resume-preserves-cache` — correct and expected, not a problem
  - `unresolvable` — a built-in `{name}` or unreadable path; nothing could be read
  - `no-meta`, `unbalanced-meta`, `rewrite-would-not-parse`, `mask-desync` — **the rewriter
    refused a script it could not prove safe.** More than a couple of these means the rewriter
    is mis-parsing real scripts; report them with the offending `form` and investigate before
    tuning anything else.
- **Deny** — now only a fallback for scripts the rewriter refused. Any `denied: true` row is
  therefore a *rewriter* failure, not a compliance failure. Treat it as a bug report.

#### Nested workflows — the known open gap

**If any row has `nested > 0`, lead with it.** A `workflow()` call inside a script runs a child
whose source the gate never sees, so the child's `agent()` calls are not rewritten and inherit the
session model — measured live at `claude-opus-5` where the parent's equivalent prompt ran on haiku.

This was left unimplemented deliberately, on the evidence that the construct had **zero** uses
across 202 persisted scripts. `nested > 0` invalidates that premise. When it appears:

1. Report how many scripts used it and estimate the untiered spend (workflow subagents in those
   sessions whose `actual_model` matches the session tier and that have no `route` row).
2. Recommend building the deferred fix — resolve a literal `scriptPath` at gate time, rewrite the
   child, cache it under `ROOT`, repoint the parent's literal — and say the counting-only
   behaviour is no longer sufficient.

Do not silently fold these into the compliance percentage; they are unenforced spend.

### 7. Propose the diff

Show proposed `policy.json` changes as a diff, each line justified with its evidence
(fire count, failure rate, token medians). Flag anything resting on fewer than ~10 samples as
low confidence. Then ask before applying.

## Notes

- The ledger is append-only and rotates at 50 MB to `ledger.jsonl.1`; include the rotated file if present.
- `session_tier` is null when the SessionStart hook could not read the session model. Those rows
  are still valid for failure analysis but cannot contribute to the savings counterfactual.
- Reading a rotated or very large ledger with `Read` will flood context. Always process it in code.
