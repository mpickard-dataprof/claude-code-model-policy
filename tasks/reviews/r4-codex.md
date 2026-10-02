Found two defects; the Git one is serious.

1. High — malicious `.git` can expose another repository’s Git history.

- `bin/agy-relay.sh:94-99, 247, 251`
- Scenario confirmed: a review directory whose `.git` file says `gitdir: /path/to/private/.git` makes `git rev-parse` report the review directory as top-level but the private repository as its common Git dir. The wrapper then read-only binds that private `.git` and passes it in `--add-dir`. `git show HEAD:secret.txt` from the review directory returned the private repo’s `TOP-SECRET`.
- This affects read-only runs too; edit validation’s top-level check does not prevent it.
- Fix: do not trust `--git-common-dir` from arbitrary `.git` metadata. For a `.git` file, validate a genuine linked-worktree chain: resolved git-dir must be beneath `<common-dir>/worktrees/`, its metadata `gitdir` must point back to this exact `<cwd>/.git`, and reject otherwise. For a normal `.git` directory, do not add an external common-dir bind.

2. Medium — configurable relay aliases fail open when the policy/hook fails.

- `hooks/gate.mjs:44-51, 527-529`
- The policy supports `agy.agent`, but crash handling only protects the literal name `agy`.
- Confirmed: with malformed policy and `agent_type: "custom-agy"`, a Bash `id` hook payload produced zero bytes (allowed); the same payload as `agent_type: "agy"` emitted deny JSON.
- Fix: make the relay identity non-configurable (`agy`) or maintain an immutable, installer-owned alias registry consulted before policy loading. Add a malformed-policy custom-alias test.

No new default-route escape found otherwise. The Bash fast path leaves non-`agy` callers untouched—no output, ledger, or session I/O—and the default `agy` relay denies on policy failure. The shared-hook-group installer split is sound on inspection; Codex routing remains separate.

I reviewed README’s agy section, CHANGELOG, and todo; checked `git diff main...HEAD` and all intervening fixes. `/usr/bin/bwrap` is present (0.9.0) and `agy` is 1.2.14. The supplied suite’s assertions through routing/grants passed; the environment terminates individual commands at 30 seconds before its slower wrapper section completes.