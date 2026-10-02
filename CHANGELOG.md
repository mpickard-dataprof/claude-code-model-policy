# Changelog

## 0.4.0 — Antigravity offload backends

### Shipped read-only

- `[agy] [edit]` is **off** (`agy.editEnabled: false`; the gate and the wrapper
  both refuse edits). Its copy-back design (private checkout copy, whole-delta
  validation) is kept but failed review: a write failing mid-apply can leave a
  partial change set. Both pools are read-only reviewers until that is fixed.

### Security

- Only a genuine linked-worktree chain exposes a Git common directory, so a
  crafted `.git` file cannot mount another repository.
- Runs see a fresh, empty, throwaway `~/.gemini/antigravity-cli` plus readonly
  copies of agy's settings, OAuth token, install id and built-ins — nothing else
  under `~/.gemini`, and nothing persists.
- The relay identity is fixed to `agy`; a policy naming another relay disables agy.

### Added

- `[gemini]` and `[agy]` offload tags through the `agy` relay. Gemini is reviews
  only and always read-only; the third-party pool's edit mode ships disabled
  (see above). Tag precedence is `[gpt]` > `[agy]` >
  `[gemini]`.
- `bin/usage-snapshot.sh` and the `agy.usageSpill` policy: a fresh local
  status-line snapshot can spill untagged sonnet/opus tasks to Antigravity when
  either Claude usage window is high.
- Antigravity now requires Linux bubblewrap. The gate creates a single-use grant,
  the relay is limited to its exact grant command, and the wrapper mounts only
  the permitted checkout and private, throwaway Antigravity state.

### Changed

- The Antigravity bubblewrap sandbox now default-denies `$HOME`, then re-exposes
  only agy's state and executable plus the granted checkout and needed Git common
  directory. The granted repository remains readable by the model (including any
  secrets committed or stored there), and the model retains network access; do
  not treat the sandbox as protection against exfiltration from that repository.

## 0.3.0 — offload to ChatGPT models, and `[hard]` means opus

### Added

- **`[gpt]` offload to OpenAI models via the Codex CLI.** A `[gpt]`-tagged spawn is
  redirected to the new `codex` agent (haiku, effort low), which hands the task to
  `bin/codex-relay.sh` and relays the answer verbatim — the reasoning runs on a
  ChatGPT subscription instead of Anthropic token billing. The tier is still scored
  and picks the OpenAI model through `codex.byTier` (`gpt-5.6-sol` / `gpt-5.6-terra` /
  `gpt-6-astra`). `codex.autoTiers` can offload whole tiers without a tag; it ships
  empty, and `neverAutoTiers` keeps haiku work on Anthropic.
- **`architect` agent** (fable, effort medium) for spawns that resolve to fable.
- **Workflow effort fill for explicit models.** `agent(p, { model: 'fable' })` now gets
  `workflow.effortByTier`'s effort when the call sets none; an explicit effort is kept.

### Changed

- **`overrides.hardTier` defaults to `opus` (was `fable`).** Measured over 102 `[hard]`
  spawns: 49% of all subagent spend, 0% `looks_failed`, and the same work routed to
  opus by the expensive-verb rule failed 2% of the time. Priced at opus the same
  tokens cost 48% less. Set it back to `fable` for the top tier. `[gpt] [hard]` now
  picks the opus-tier OpenAI model accordingly.
- The session brief reads the tag tiers from `policy.json` instead of hardcoding them.

### Fixed

- **A test failed only on macOS.** `/bin/bash` 3.2 mangles regex backslashes in a
  single-quoted string nested inside `$(...)`, so the effort-fill probe extracted
  nothing. The probe now runs from a quoted heredoc file; 140/140 under bash 3.2 and 5.

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
