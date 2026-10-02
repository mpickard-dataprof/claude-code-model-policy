# Antigravity (agy) offload — plan (owner-approved 2026-10-01)

Two new offload backends via Google's `agy -p` CLI, parallel to `[gpt]`/Codex.

## Decisions (owner)
- Two tags, tag-only by default: `[gemini]` -> agy Gemini pool; `[agy]` -> agy third-party pool (Claude + GPT-OSS).
- Gemini map: haiku->gemini-3.8-flash-low, sonnet->gemini-3.8-flash-medium, opus->gemini-3.1-pro-high, fable->gemini-3.1-pro-high.
- Third-party map: haiku->gpt-oss-120b-medium, sonnet->claude-sonnet-4-6, opus->claude-opus-4-6-thinking, fable->claude-opus-4-6-thinking.
- Roles (owner): `[gemini]` = REVIEWS ONLY, always read-only (never accept-edits, even in a worktree). `[agy]` = reviews + development.
- Access: read-only by default (agy default perms + read-only allow-list in ~/.gemini/antigravity-cli/settings.json);
  `--mode accept-edits` (file edits, NO shell) only for the `[agy]` pool AND only when cwd is under a `.worktrees/` dir. Never --dangerously-skip-permissions.
  Claude runs the tests afterwards.
- Usage auto-spill: statusline writes `rate_limits` snapshot to `<install>/usage.json`; gate reads it.
  If five_hour.used_percentage >= 80 AND snapshot < 10 min old -> untagged offloadable sonnet/opus spawns go to `[agy]` pool.
  Stale/missing snapshot -> no spill. Ledger records `offload_via: "auto:usage"`.

## Tasks
- [ ] policy.json: `agy` block {enabled, agent, offloadableTypes, pools:{gemini:{tag,byTier}, thirdparty:{tag,byTier}}, relayTier, usageSpill:{enabled, pool, fiveHourPct, maxAgeSec, tiers}}
- [ ] lib.mjs: generalize resolveCodexOffload -> backend resolver (codex | agy:<pool>); AGY-OFFLOAD preamble + marker; stripOffloadPreamble handles both; usage snapshot reader
- [ ] gate.mjs: ledger fields `offload: "agy"`, `offload_pool`, `offload_via`
- [ ] bin/agy-relay.sh + supervisor (validate model vs policy, cwd, worktree check for accept-edits, timeout, single JSON line out)
- [ ] agents/agy.md relay agent (haiku/low), installed like codex.md
- [ ] brief.mjs: document `[gemini]` / `[agy]` / usage spill
- [ ] statusline snippet writing usage.json (atomic write)
- [ ] test.sh: tag routing, pool maps, read-only vs worktree mode, usage spill (fresh/stale/missing/below threshold), preamble split, ledger
- [ ] CHANGELOG 0.4.0, README
- [ ] Reviews: Codex + Claude (Opus) on the diff; live smoke test of both pools; install + verify.sh
