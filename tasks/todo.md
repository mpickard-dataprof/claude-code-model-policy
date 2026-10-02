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
- [x] policy.json + mandatory bubblewrap sandbox configuration
- [x] gate/lib routing, immutable task files, single-use grants and relay lockdown
- [x] agy wrapper: grant validation, sandboxed launch, and JSON outcome handling
- [x] agy relay agent (Bash/Read only), SessionStart brief, per-account usage snapshot
- [x] test.sh: routing, grants, relay hook, sandbox binds, usage spill and wrapper guards
- [x] CHANGELOG 0.4.0, README
- [x] Reviews: rounds 1-5 (Codex + Opus); live smoke tests of both pools. Round 5 not clean on edit mode -> shipped with [agy] [edit] OFF (2026-10-02).

## Follow-up (after agy build lands)
- [ ] Re-enable [agy] [edit]: make copy-back transactional (stage + rollback, or report partial application), then a fresh review round. Code is in place behind agy.editEnabled; see tasks/reviews/r5-codex.md.
- [ ] Gemini test-runner role: per-project allow-listed test script; returns pass/fail counts + per-failure name/cause/file. Long timeout (GridGrade suite ~50 min). Owner runs the allow-list setup. Spot-check EVERY run while on probation (tasks/gemini-track-record.md).
- [x] model-policy-tune skill (skill/SKILL.md): new step before "7. Propose the diff" — "Offload backends on probation": read tasks/gemini-track-record.md + agy ledger rows (offload:"agy", by pool/task type); report accuracy per task type; recommend promote (e.g. Gemini as a counted reviewer, test-runner without spot-checks) / keep probation / demote; promotions need the owner's OK and are recorded in policy.json + the track record. Owner request 2026-10-01.
- [x] Graceful when agy is absent (MacBook/s2server have no agy yet): no [gemini]/[agy]/usage-spill routing when the configured agy binary is missing (check at SessionStart, record in session state); brief says so.
- [ ] Ship: PR -> merge -> on linux workstation, mbp, s2server: git pull ~/.claude-shared/model-policy + ./install.sh + ./verify.sh (owner request 2026-10-01). s2server has untracked SPEC.md in the install — leave it.
