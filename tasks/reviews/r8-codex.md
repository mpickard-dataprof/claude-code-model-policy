Round 8 (Codex, gpt-5.6-terra high) on 647a1d2. Round-7 fixes verified (sanitiser, system gitconfig, bare-repo deletions, filesystem-driven rollback: no wrong restore/unlink found).

1. High (Codex) — /usr, /etc, /opt are mounted readable, so a git repo with credentials kept there would be readable. Same for read-only runs; was listed as accepted scope. None exist on this workstation (no .git under /opt, /usr, /etc). Residual, documented.
2. High (conditional) — abstract AF_UNIX sockets share the network namespace, so same-UID host services listening on them are reachable. Already documented in README as a residual risk of shared networking; affects all runs.
3. Medium — edits inside a pre-existing nested repo (ancestor with its own .git) passed. FIXED: reject any changed path below a host ancestor holding .git; test + mutation check.
