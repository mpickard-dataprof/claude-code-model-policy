# Handoff: finish agy [edit] mode (2026-10-02)

## Owner decision
One more attempt to finish `[agy] [edit]` properly. If the next review round still finds
holes in edit mode, FALL BACK: ship with edit mode disabled (Gemini + agy pools do read-only
reviews only; usage spill still routes read-only work). Then push to GitHub and sync this
workstation, the MacBook (`mbp`) and `s2server` (git pull in ~/.claude-shared/model-policy,
./install.sh, ./verify.sh). agy is not installed on mbp/s2server, so it must stay inactive there.

## State
- Branch `feat/agy-offload`, worktree `~/Projects/claude-code-model-policy/.worktrees/agy-offload`,
  HEAD b94e0fa (+ this handoff), `./test.sh` 270/270. Not merged, not pushed, not installed.
- Plan + owner decisions: `tasks/todo.md`. Gemini probation record: `tasks/gemini-track-record.md`.
- Review reports: `tasks/reviews/r1..r4-codex.md` (Codex). The Opus round-4 findings are summarised
  below. Live attack script used for verification: `tasks/reviews/attack_battery.sh` (run as a fake
  agy binary through the wrapper with a throwaway policy + grants dir; see test.sh `grant()`).

## Open findings (round 4)
1. Opus: [edit] runs can leave files in the worktree that host tools later execute (a nested
   `.github/workflows` mask bypassed via parent rename; uncovered config dirs such as `.codex/`,
   `.gemini/`). Block lists don't converge. Intended direction (owner-approved in plain terms):
   the edit run works on a throwaway copy of the worktree, and only ordinary changed files are
   copied back after validation against an allow-list; anything else rejects the whole change set.
   This also replaces the edit masks and placeholder cleanup.
2. Codex: a crafted `.git` file can point the git common dir at an unrelated repo, which is then
   mounted read-only (validate the linked-worktree chain; no external common dir for a normal .git dir).
3. Opus: read-only runs can write persistent agy memory (brain/implicit/...) - give every run a
   private throwaway copy of agy state.
4. Codex: relay identity is configurable, so fail-closed only covers the literal `agy` - make it fixed.
5. Opus (low): nested bare-repo layouts evade the `.git` name check (moot under item 1's allow-list).

## Process (owner rules)
Codex builds with tests; I verify each test fails when its fix is reverted; live-test with real
bwrap + real agy (Gemini review, Claude worktree edit) and the attack script; then BOTH independent
reviews (Codex + Opus `[hard]`). Clean round -> ship. Not clean on edit mode -> fallback above.

## Outcome (2026-10-02)
Copy-back built (Codex), mutation-checked, live-tested with real bwrap + agy and the attack battery.
Round-5 Codex review still found an edit-mode hole (non-transactional apply) -> FALLBACK taken:
edit mode shipped off behind `agy.editEnabled`. Fixed in the same round: ~/.gemini exposure,
baseline location, nested bare repos. Details: tasks/reviews/r5-codex.md.
