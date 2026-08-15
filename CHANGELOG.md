# Changelog

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
