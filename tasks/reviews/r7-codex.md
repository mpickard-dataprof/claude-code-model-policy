Round 7 (Codex, gpt-5.6-terra high) on 4b7dba8 — not clean. All four fixed by Claude in the following commit.

1. High — sanitised git config kept branch.*.remote and extensions.* values, which can be credential-bearing URLs (reproduced). FIXED: core basics + extensions.(worktreeconfig|objectformat|refstorage) only, values must match [A-Za-z0-9_.-]{1,64}. Affects LIVE read-only runs.
2. High (conditional) — /etc is mounted, so a system /etc/gitconfig with credentials would be readable and used by git. Not present on this workstation. FIXED: /etc/gitconfig blanked when present, GIT_CONFIG_NOSYSTEM=1 in the box.
3. Medium — deletions inside a pre-existing bare repo bypassed the git_repo rule. FIXED: rule covers every changed path, checked in the copy and the host tree.
4. Low — a signal between a rename and its journal flag could leave an unlisted backup. FIXED: rollback and leftover reporting follow the filesystem, not the flags. (Not unit-testable deterministically.)
