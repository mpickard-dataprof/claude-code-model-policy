#!/bin/sh
# Launcher for the model-policy hooks.
#
# Claude Code hooks inherit the environment of the process that launched Claude.
# When node is managed by nvm that PATH is only populated by interactive shells,
# so a hook relying on `#!/usr/bin/env node` can silently never run — the worst
# kind of failure, because nothing reports it.
#
# This finds a usable node the same way on every machine, and fails open: if no
# node exists at all we exit 0 with no output and the tool call proceeds
# exactly as it would have without the hook.
#
# usage: run.sh <hook-script.mjs>

SCRIPT="$1"
[ -n "$SCRIPT" ] || exit 0
[ -f "$SCRIPT" ] || exit 0
shift

# 1. Whatever is already on PATH.
if command -v node >/dev/null 2>&1; then
  exec node "$SCRIPT" "$@"
fi

# 2. Standard system / Homebrew locations (Apple Silicon, Intel, Linux).
for candidate in /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node /snap/bin/node; do
  if [ -x "$candidate" ]; then
    exec "$candidate" "$SCRIPT" "$@"
  fi
done

# 3. An nvm install, if any. Glob directly rather than $(ls ... | tail -1):
#    unquoted command substitution word-splits on IFS, so a space anywhere in the
#    path yields a fragment — and it avoids depending on `ls`/`tail` being present,
#    which matters precisely when PATH is broken.
nvm_node=""
for candidate in "$HOME"/.nvm/versions/node/*/bin/node; do
  [ -x "$candidate" ] && nvm_node="$candidate"
done
if [ -n "$nvm_node" ]; then
  exec "$nvm_node" "$SCRIPT" "$@"
fi

# No node anywhere: fail open rather than break the tool call.
exit 0
