Found two serious issues.

1. **Critical — sandboxed agy can exfiltrate arbitrary host-readable files via `/relay` symlink substitution.**  
   [bin/agy-relay.sh:99, 174, 182, 193–224](bin/agy-relay.sh:99)

   `/relay` is a writable bind of the host `OUTDIR`. The worker can replace `answer.md` or `stderr.log` with an absolute symlink after the supervisor has opened its output FD. Later, the host wrapper reopens those paths by name and follows the symlink.

   Confirmed with real `/usr/bin/bwrap`: a fake worker replaced `/relay/answer.md` with a symlink to a controlled host-only file. The wrapper returned `ok:true` and emitted that file’s contents, despite a read-only grant.

   Fix: do not bind `OUTDIR` writable. Bind only the task file read-only at `/relay/task.md`; agy’s stdout is already captured by the supervisor. Also use `O_NOFOLLOW`/descriptor-based reads for all host-side output/error/result handling as defense in depth.

2. **High — `[agy] [edit]` can plant project-local Claude Code configuration for later host execution.**  
   [bin/agy-relay.sh:134–145](bin/agy-relay.sh:134)

   Edit mode RW-binds the entire worktree at `/workspace`, including `.claude/`. A sandbox probe successfully created host-side `/workspace/.claude/settings.json`. That file can define project hooks/permissions; Claude Code treats `.claude/settings.json` and `.claude/settings.local.json` as project settings, including hooks, and reloads settings changes. [Claude Code settings docs](https://code.claude.com/docs/en/settings)

   Fix: after binding the worktree, mount an empty tmpfs over `/workspace/.claude` (and consider masking other Claude project-control files such as `.mcp.json`). Add a real-bwrap regression test that attempts to create `.claude/settings.json` and verifies it does not persist.

3. **Moderate regression — widened hook matcher adds measurable latency to every ordinary file/tool call.**  
   [install-merge.mjs:22](install-merge.mjs:22), [hooks/gate.mjs:40–60](hooks/gate.mjs:40)

   The fast path does no ledger/session I/O and emits nothing for non-`agy` callers, and crashes fail open. But every main-thread `Read`/`Glob`/`Grep`/`Bash` now launches `run.sh` and Node before it can return. I measured 10 ordinary `Read` calls at **45.8 ms each**. The early JS return cannot avoid process startup.

   Fix: either accept/document this cost for defense in depth, or narrow the matcher back to `Bash` and rely on the relay’s declared `disallowedTools` for the other tools.

4. **Test regression — new installer-isolation assertion is never executed.**  
   [test.sh:291](test.sh:291) calls `assert` before its definition at [test.sh:314](test.sh:314). `./test.sh` emits `assert: command not found` and continues because it lacks `set -e`, silently skipping the new upgrade-safety check. Move the helper definition before first use and make command-not-found failures fatal.

No grant forgery/replay, non-edit write escalation, or relay-tool bypass found beyond the `/relay` symlink escape. No repository files were modified.