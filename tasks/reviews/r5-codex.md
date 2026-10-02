Round 5 (Codex, gpt-5.6-terra high) on 22d665b — not clean. Opus round-5 review did not complete (stopped by a classifier twice); owner accepted Codex alone for this round.

1. High — the whole real ~/.gemini was readable in the box (OAuth token, history, plus, found on follow-up, a browser profile and other tools' chat history), and the private state was seeded from host history. FIXED: box sees a fresh empty antigravity-cli tree plus readonly settings.json, antigravity-oauth-token, installation_id, builtin only. Token exposure remains a documented exception.
2. High — copy-back is not transactional: an error mid-apply (unwritable dir, ENOSPC, failed unlink) leaves earlier files replaced while reporting edit_rejected. OPEN -> edit mode shipped OFF (agy.editEnabled false; gate and wrapper both refuse).
3. Medium — edit-baseline.json lived in PRIVTMP, the box's writable /tmp, so the worker could forge the baseline. FIXED: baseline under OUTDIR (not bound into the box).

Also found by Claude during live testing: nested bare repos (sub/r.git/..., or any dir with HEAD+objects/+refs/) passed the path allow-list. FIXED with a git_repo rule + tests.
