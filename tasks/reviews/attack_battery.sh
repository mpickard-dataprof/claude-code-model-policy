#!/bin/bash
# Fake agy: runs inside the sandbox and tries every known escape. Prints one line per attempt.
# "ok:" = the action succeeded inside the box (may still be harmless — the host checks decide).
t(){ if bash -c "$1" >/dev/null 2>&1; then echo "ok: $1"; else echo "blocked: $1"; fi; }
M=/home/matt/.cache/agylive
t "printf 'gitdir: /workspace/.g' > /workspace/.git"
t "echo x > /workspace/.git/evil"
t "echo x > $M/outside.txt"
t "echo x > $M/repo/.worktrees/wt/DIRECT_HOST_WRITE"
t "mkdir -p /workspace/.claude && echo '{}' > /workspace/.claude/settings.json"
t "mkdir -p /workspace/.github/workflows && echo x > /workspace/.github/workflows/x.yml"
t "mkdir -p /workspace/.codex && echo x > /workspace/.codex/config.toml"
t "mkdir -p /workspace/sub && echo evil > /workspace/sub/CLAUDE.md"
t "echo x > /workspace/.mcp.json"
t "mkdir -p /workspace/sub/r.git/hooks && echo x > /workspace/sub/r.git/config"
t "ln -s /home/matt/.ssh /workspace/sshlink"
t "chmod +x /workspace/m.py"
t "mkdir -p /home/matt/.gemini/extensions/evil && echo x > /home/matt/.gemini/extensions/evil/x"
t "echo x >> /home/matt/.gemini/antigravity-cli/settings.json"
t "echo PERSIST > /home/matt/.gemini/antigravity-cli/brain/ATTACK_MEMORY"
t "echo PERSIST >> /home/matt/.gemini/antigravity-cli/history.jsonl"
t "echo x > /home/matt/.gemini/antigravity-cli/bin/agentapi"
t "cat /home/matt/.ssh/config"
t "ls /home/matt/Documents"
t "cat /home/matt/.claude-personal/.credentials.json | grep -q ."
t "ls /run/user/1000"
t "systemd-run --user /bin/sh -c 'date > $M/ESCAPED_SYSTEMD'"
t "busctl --user list"
t "SSH_AUTH_SOCK=/run/user/1000/gcr/ssh ssh-add -l"
t "test -n \"\$SSH_AUTH_SOCK\$DBUS_SESSION_BUS_ADDRESS\$XDG_RUNTIME_DIR\$DISPLAY\""
t "kill -0 1 && ps -e | grep -q systemd"
echo DONE
