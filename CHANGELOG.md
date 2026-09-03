# Changelog

## 0.2.0 — a ledger you can actually join

Analysing three weeks of real spawns (1,586 rows, two machines) turned up two defects that
made the ledger's own numbers unreliable. Both are fixed here, and the tuning skill now
knows about them.

### Fixed

- **`complete` rows double-counted spend.** SubagentStop fires repeatedly for one
  long-running agent and each firing re-reads the whole transcript, so rows for an
  `agent_id` supersede each other rather than accumulating. Summing them over-reported
  spend by 20% ($490.66 against $390.76 true). Rows now carry **`stop_seq`**; keep the
  highest per `agent_id`.
- **The join key could pair the wrong two rows.** `prompt_fp` holds only the first 100
  characters, and a fan-out's agents share a preamble — 122 fingerprints repeated inside a
  single session, one of them 11 ways. Rows now carry **`prompt_sha`**, a hash over the
  whole normalised prompt. `prompt_fp` is kept as a graceful fallback and for older rows.
- **Workflow agents looked like they had escaped the gate.** An `agent()` call that passes
  its own `agentType` is indistinguishable from an Agent-tool spawn at SubagentStop, so it
  appeared in the Agent-tool population with no `route` row. Rows now carry **`routed`**,
  recorded by the gate itself through a per-session append-only sidecar.

### Added

- `prompt_id` on both row types — the host's own spawn identifier, recorded as-is.
- 13 tests, including the first coverage of `log.mjs`, which previously had none.

### Documentation

- The "Never raises cost" guarantee was stated without its exception. `[cheap]` and
  `[hard]` are explicit overrides and deliberately bypass every clamp — including the agent
  definition's declared model, so `[hard]` on a `worker` runs above the sonnet it declares.
  Both the guarantee and the tag table now say so.
- New "What it records" section covering every ledger field and which ones hold prompt text.

## 0.1.0 — first public release

Initial release. Extracted from a working setup across three machines and generalized.

### Features

- **Agent tiering** — a fixed table for known agent types, prompt scoring for generic ones.
- **Workflow enforcement** — inline scripts, `{scriptPath}` and `{name}` forms are rewritten
  so `agent()` calls with no model get one chosen at runtime from the actual prompt.
- **Effort tiering** — `scout` (haiku/low) and `worker` (sonnet/medium) agent definitions,
  since `effort` cannot be passed through the `Agent` tool's schema.
- **Three clamps** — a resolved tier never exceeds the requested model, the agent
  definition's own declared model, or the session model.
- **Ledger** — routing decisions and outcomes, including `actual_model` read back from each
  subagent's transcript.
- **`/model-policy-tune`** — analyses the ledger and proposes `policy.json` edits.
- **`disabledTiers`** — tiers your account cannot use fall back to the next cheaper one;
  the installer pre-fills this from models observed in your transcripts.
- **`verify.sh`**, **`deploy-check.py`**, **`uninstall.sh`**.

### Known limitations

- A `workflow()` call nested inside a script runs a child the gate never sees; its
  `agent()` calls are counted and warned about, not rewritten. Patching `globalThis.agent`
  was tried and measured as ineffective — see `docs/DESIGN.md`.
- `effort` is set on the Workflow path but Claude Code does not persist it to the agent
  metadata the way it does `model`, so it is verified in test rather than from a live artefact.
- Windows is untested; the hooks and scripts assume a POSIX shell.
