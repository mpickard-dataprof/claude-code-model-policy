Round 6 (Codex, gpt-5.6-terra high) on 4919d65 (transactional copy-back) — not clean. Owner chose: fix all four, round 7.

1. Critical — `trap cleanup_private EXIT INT TERM` does not exit. SIGINT/SIGTERM during `wait "$SUP_PID"` deletes COPYDIR, then the script continues into copy-back, which sees an empty copy and commits every baseline file as a deletion. Pre-existing since the copy-back design (22d665b). Not live on main (edit off).
2. High — linked-worktree common git dir is mounted readable; its config can hold credential-bearing remote URLs (also .git/config of a normal checkout in read-only mode, FETCH_HEAD). Affects the LIVE read-only reviews.
3. High (Codex) / judged low by Claude — non-dot CI config names (Jenkinsfile, azure-pipelines.yml, ...) pass the path rule. Run only after commit+push (reviewed), same class as Makefile; deny the known names anyway.
4. Medium — a backup unlink failure after commit returns ok:true with leftovers; stale .agy-stage-/.agy-bak- files from an earlier run are not detected.
