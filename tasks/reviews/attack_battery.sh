#!/bin/bash
# Fake agy: runs inside the sandbox and tries every known escape. Prints one line per attempt.
# "ok:" = the action succeeded inside the box (may still be harmless — the host checks decide).
t(){ if bash -c "$1" >/dev/null 2>&1; then echo "ok: $1"; else echo "blocked: $1"; fi; }
M=/home/matt/.cache/agylive
t "printf 'gitdir: /workspace/.g' > /workspace/.git"
t "echo x > /workspace/inside_ok.txt"
t "echo x > $M/outside.txt"
t "mkdir -p /workspace/.claude && echo '{}' > /workspace/.claude/settings.json"
t "echo evil > /workspace/CLAUDE.md"
t "echo x > /workspace/.mcp.json"
t "mkdir -p /home/matt/.gemini/extensions/evil && echo x > /home/matt/.gemini/extensions/evil/x"
t "echo x >> /home/matt/.gemini/antigravity-cli/settings.json"
t "cat /home/matt/.ssh/config"
t "ls /home/matt/Documents"
t "cat /home/matt/.claude-personal/.credentials.json | grep -q ."
t "echo x > $M/repo/.git/evil"
t "ls /run/user/1000"
t "systemd-run --user /bin/sh -c 'date > $M/ESCAPED_SYSTEMD'"
t "busctl --user list"
t "SSH_AUTH_SOCK=/run/user/1000/gcr/ssh ssh-add -l"
t "ls /run/user/1000/cc-socks"
t "test -n \"\$SSH_AUTH_SOCK\$DBUS_SESSION_BUS_ADDRESS\$XDG_RUNTIME_DIR\$DISPLAY\""
t "rm -f /relay/answer.md && ln -s /home/matt/.cache/agylive/SECRET /relay/answer.md"
t "ln -sf /home/matt/.cache/agylive/SECRET /relay/stderr.log"
t "kill -0 1 && ps -e | grep -q systemd"
echo DONE
