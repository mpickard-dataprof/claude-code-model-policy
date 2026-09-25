#!/usr/bin/env python3
"""Launch `codex exec`, supervise it, and emit the one JSON result line.

This is a SINGLE owner on purpose. The previous design split the job between a
bash trap and a python watchdog, and every one of those seams produced a bug:

  * bash trapped TERM but python had already launched the worker, so a signal in
    the gap between `Popen` and python's own handler registration killed the
    supervisor and orphaned codex — while bash cheerfully reported "the worker
    was torn down";
  * two signals in quick succession re-entered the bash trap and printed two
    complete JSON objects, so the caller parsed a result that was half of a pair;
  * the grace period was measured against the group LEADER, so a leader that died
    instantly on TERM caused an immediate KILL of descendants that were still
    cleaning up.

One process now owns launch, signals, teardown and emission, so those states
cannot disagree.

Known limit, stated rather than papered over: containment is by process GROUP. A
descendant that calls setsid() to create its own session escapes it. Guaranteeing
otherwise needs OS-level containment (a cgroup on Linux), which this does not
attempt. Cancellation therefore stops codex and its ordinary children, and it is
not a guarantee against a deliberately detaching grandchild.
"""

import json
import os
import signal
import subprocess
import sys
import time

GRACE_SECONDS = 5


def emit(**kw):
    """The ONE emission path. Reached AT MOST ONCE per invocation.

    There are several call sites, but they are mutually exclusive: each is
    followed by a return. Signal handlers never emit — they set a flag.
    """
    out = {
        "ok": False, "exit_code": -1, "reason": None, "output_file": None,
        "output_bytes": 0, "model": None, "effort": None, "sandbox": None,
        "elapsed_s": 0, "stderr_tail": None, "teardown": None,
    }
    out.update(kw)
    sys.stdout.write(json.dumps(out) + "\n")
    sys.stdout.flush()


def group_members(pgid):
    """(scan_ok, pids) for the worker's process group, excluding ourselves.

    The status is returned SEPARATELY and must not be collapsed into the list.
    Returning [] on a failed scan meant "could not inspect" was indistinguishable
    from "nothing survives" — reproduced with a failing `ps`, a surviving child
    was reported as a clean success.
    """
    try:
        res = subprocess.run(["ps", "-A", "-o", "pid=,pgid="],
                             capture_output=True, text=True, timeout=5)
    except Exception:
        return (False, [])
    if res.returncode != 0:
        return (False, [])
    alive = []
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) != 2:
            continue
        try:
            pid, gid = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        if gid == pgid and pid != os.getpid():
            alive.append(pid)
    return (True, alive)


def main():
    (timeout_s, out_path, err_path, stdout_path, task_path,
     sandbox, model, effort, cwd) = sys.argv[1:10]
    timeout_s = int(timeout_s)
    started = time.time()

    # Handlers are installed BEFORE the worker exists. A signal arriving in the
    # gap between launch and registration was the reproduced orphan case, so
    # there is deliberately no gap: the flag is set, and the main loop acts on
    # it. Handlers only set a flag — they never tear down or emit, which is what
    # made the old bash trap re-entrant.
    state = {"cancelled": None}

    def on_signal(signum, _frame):
        if state["cancelled"] is None:
            state["cancelled"] = signum

    for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        try:
            signal.signal(s, on_signal)
        except Exception:
            pass

    argv = [
        "codex", "exec", "--skip-git-repo-check",
        "-C", cwd, "-s", sandbox, "-m", model,
        "-c", "model_reasoning_effort=%s" % effort,
        "-o", out_path, "-",
    ]

    try:
        fin = open(task_path, "rb")
        fout = open(stdout_path, "wb")
        ferr = open(err_path, "wb")
    except Exception as exc:
        emit(reason="could not open worker io: %s" % exc, exit_code=2,
             model=model, effort=effort, sandbox=sandbox)
        return 2

    try:
        proc = subprocess.Popen(argv, stdin=fin, stdout=fout, stderr=ferr,
                                start_new_session=True)
    except FileNotFoundError:
        emit(reason="codex CLI not found on PATH", exit_code=2,
             model=model, effort=effort, sandbox=sandbox)
        return 2
    except Exception as exc:
        emit(reason="could not start codex: %s" % exc, exit_code=2,
             model=model, effort=effort, sandbox=sandbox)
        return 2

    try:
        pgid = os.getpgid(proc.pid)
    except Exception:
        pgid = proc.pid

    def group_empty():
        """True only when the scan SUCCEEDED and found nothing."""
        scan_ok, members = group_members(pgid)
        return scan_ok and not members

    def tear_down():
        """TERM the group, let it EMPTY within the grace period, then KILL.

        Grace is measured against surviving GROUP MEMBERS, not the leader. A
        leader that dies instantly on TERM used to end the grace period at once,
        so descendants mid-cleanup were KILLed immediately.

        Runs for EVERY exit path that may leave members behind, including a
        leader that had already finished: skipping straight to KILL because the
        leader was gone denied its children the grace they were owed.
        """
        try:
            os.killpg(pgid, signal.SIGTERM)
        except Exception:
            try:
                proc.send_signal(signal.SIGTERM)
            except Exception:
                pass
        deadline = time.monotonic() + GRACE_SECONDS
        while time.monotonic() < deadline:
            if proc.poll() is not None and group_empty():
                return True
            time.sleep(0.1)
        try:
            os.killpg(pgid, signal.SIGKILL)
        except Exception:
            try:
                proc.send_signal(signal.SIGKILL)
            except Exception:
                pass
        # Confirm rather than assume: the caller is told what was verified.
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if proc.poll() is not None and group_empty():
                return True
            time.sleep(0.1)
        return False

    # Absolute deadline, not an iteration count: suspending this process must not
    # buy the worker extra runtime.
    deadline = time.monotonic() + timeout_s
    timed_out = False
    torn_down_cleanly = None

    while True:
        # Cancellation is checked BEFORE leader completion: a leader that exited
        # in the same instant used to route past tear_down() entirely, so its
        # children were KILLed with no TERM and no grace.
        if state["cancelled"] is not None:
            torn_down_cleanly = tear_down()
            break
        if proc.poll() is not None:
            break
        if time.monotonic() >= deadline:
            timed_out = True
            torn_down_cleanly = tear_down()
            break
        time.sleep(0.2)

    # Distinguish "exited" from "we gave up waiting" rather than inventing a code.
    code = proc.poll()
    if code is None:
        try:
            code = proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            code = None  # genuinely unknown; do not fabricate one
        except Exception:
            code = None

    # Even a naturally-completed leader can leave children behind. They get the
    # same TERM/grace/KILL treatment rather than an immediate KILL.
    scan_ok, strays = group_members(pgid)
    if strays or not scan_ok:
        if torn_down_cleanly is None:
            torn_down_cleanly = tear_down()
        scan_ok, strays = group_members(pgid)

    elapsed = int(time.time() - started)
    nbytes = 0
    try:
        nbytes = os.path.getsize(out_path)
    except Exception:
        pass

    if state["cancelled"] is not None:
        # Do not assert a teardown here; the `teardown` field is the only thing
        # entitled to draw that conclusion, and it may say otherwise.
        ok, reason = False, "cancelled: signal %d" % state["cancelled"]
    elif timed_out:
        ok, reason = False, "timed out after %ds" % timeout_s
    elif code is None:
        ok, reason = False, "worker did not exit and could not be reaped"
    elif code != 0:
        ok, reason = False, "codex exited %d" % code
    elif nbytes == 0:
        ok, reason = False, "codex produced no output"
    else:
        ok, reason = True, None

    # Never claim a teardown that was not observed — and never return success
    # alongside surviving work. A warning appended to `reason` while `ok` stayed
    # true was invisible to the relay, which branches on `ok`.
    if not scan_ok:
        teardown = "unknown: could not inspect the process group"
    elif strays:
        teardown = "incomplete: %d process(es) survive" % len(strays)
    elif torn_down_cleanly is False and code is None:
        # Only `unconfirmed` while something is still genuinely unresolved. A
        # successful FINAL scan that finds the group empty supersedes a teardown
        # confirmation that failed earlier — inspection recovering after a
        # transient failure used to fail an otherwise clean run.
        teardown = "unconfirmed"
    else:
        teardown = "clean"

    if teardown != "clean":
        ok = False
        reason = ((reason + "; ") if reason else "") + "TEARDOWN " + teardown

    tail = None
    if not ok:
        try:
            # Seek, do not slurp. A noisy failing worker can write a very large
            # stderr log, and reading all of it to keep 600 characters put the
            # memory pressure exactly where the failure report was needed.
            with open(err_path, "rb") as fh:
                fh.seek(0, os.SEEK_END)
                fh.seek(max(0, fh.tell() - 4096))
                # read(4096), not read(): a still-running logger appending after
                # the seek made the "bounded" read unbounded again — 8 MB was
                # read to keep 600 characters.
                tail = fh.read(4096).decode("utf-8", "replace")[-600:] or None
        except Exception:
            pass

    emit(ok=ok, exit_code=(code if code is not None else -1), reason=reason,
         output_file=out_path, output_bytes=nbytes, model=model, effort=effort,
         sandbox=sandbox, elapsed_s=elapsed, stderr_tail=tail,
         teardown=teardown)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
