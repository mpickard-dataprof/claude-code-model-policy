#!/usr/bin/env bash
# Remove the model-policy hooks, skill link and agent links from every Claude Code
# config dir. Leaves this directory — and your ledger — alone; delete it yourself
# if you want the collected data gone too.
#
#   bash uninstall.sh              remove THIS install from every config dir
#   bash uninstall.sh --dry-run    show what would change, touch nothing
#   bash uninstall.sh --all        also remove hooks pointing at OTHER model-policy
#                                  installs (use if you moved the directory)
set -uo pipefail

SHARED_DIR="$(cd "$(dirname "$0")" && pwd)"
DRY=0
ALL=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --all)     ALL=1 ;;
    *) echo "unknown option: $a"; exit 2 ;;
  esac
done

find_node() {
  if command -v node >/dev/null 2>&1; then command -v node; return 0; fi
  for c in /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node /snap/bin/node; do
    [ -x "$c" ] && "$c" -e '' >/dev/null 2>&1 && { echo "$c"; return 0; }
  done
  nvm_node=""
  for c in "$HOME"/.nvm/versions/node/*/bin/node; do [ -x "$c" ] && nvm_node="$c"; done
  [ -n "$nvm_node" ] && { echo "$nvm_node"; return 0; }
  return 1
}
NODE_BIN="$(find_node)" || { echo "! node not found — cannot edit settings.json safely"; exit 1; }

echo "model-policy uninstall"
[ "$DRY" = 1 ] && echo "  (dry run — nothing will be changed)"
echo

CHANGED=0
for d in "$HOME"/.claude*; do
  [ -d "$d" ] || continue
  # Skip our own install directory, however it is named.
  case "$SHARED_DIR/" in "$d"/*) continue ;; esac
  [ -f "$d/settings.json" ] || continue

  OUT="$("$NODE_BIN" -e '
    const fs = require("fs");
    const [file, dry, root, all] =
      [process.argv[1], process.argv[2] === "1", process.argv[3], process.argv[4] === "1"];
    let raw, s;
    try { raw = fs.readFileSync(file, "utf8"); s = JSON.parse(raw); }
    catch (e) { console.log("SKIP unreadable/invalid JSON"); process.exit(0); }

    let removed = 0;
    const hooks = s.hooks || {};
    for (const [ev, arr] of Object.entries(hooks)) {
      if (!Array.isArray(arr)) continue;
      for (const matcher of arr) {
        if (!Array.isArray(matcher.hooks)) continue;
        const before = matcher.hooks.length;
        // Scope to THIS install by default. A command pointing at a different
        // model-policy directory belongs to another install and is not ours to
        // remove — the same rule the symlink check below follows. --all overrides.
        // Identify our hooks by the script FILENAMES we ship, not by the install
        // directory being named "model-policy" — the directory can be called
        // anything, and a name-based match silently misses those installs.
        const OURS = ["hooks/gate.mjs", "hooks/brief.mjs", "hooks/log.mjs"];
        matcher.hooks = matcher.hooks.filter((h) => {
          const c = String(h.command || "").replace(/\\/g, "/");
          if (!OURS.some((f) => c.includes(f))) return true;
          // Scope to THIS install by default. A command pointing at a different
          // install is not ours to remove — the same rule the symlink check below
          // follows. --all overrides.
          return all ? false : !c.includes(root);
        });
        removed += before - matcher.hooks.length;
      }
      // Drop matcher entries we emptied, and the event key if it is now empty.
      hooks[ev] = arr.filter((m) => Array.isArray(m.hooks) && m.hooks.length > 0);
      if (hooks[ev].length === 0) delete hooks[ev];
    }
    if (Object.keys(hooks).length === 0) delete s.hooks; else s.hooks = hooks;

    if (removed === 0) { console.log("none"); process.exit(0); }
    if (dry) { console.log("WOULD remove " + removed); process.exit(0); }

    // Back up before writing, exactly as install.sh does.
    try { fs.copyFileSync(file, file + ".model-policy-uninstall.bak"); } catch {}
    const out = JSON.stringify(s, null, 2) + "\n";
    JSON.parse(out); // never write something we cannot read back
    fs.writeFileSync(file, out);
    console.log("removed " + removed);
  ' "$d/settings.json" "$DRY" "$SHARED_DIR" "$ALL")"

  LINKS=0
  for l in "$d/skills/model-policy-tune" "$d/agents/scout.md" "$d/agents/worker.md" "$d/agents/codex.md" "$d/agents/agy.md"; do
    # Only remove links that point into THIS install. A user's own file of the same
    # name must survive an uninstall untouched.
    if [ -L "$l" ]; then
      target="$(cd "$(dirname "$l")" && readlink "$l")"
      case "$target" in
        "$SHARED_DIR"/*)
          if [ "$DRY" = 1 ]; then LINKS=$((LINKS + 1)); else rm -f "$l" && LINKS=$((LINKS + 1)); fi ;;
      esac
    fi
  done

  if [ "$OUT" != "none" ] || [ "$LINKS" -gt 0 ]; then
    echo "  $(basename "$d"): hooks $OUT, links $LINKS"
    CHANGED=$((CHANGED + 1))
  fi
done

echo
if [ "$CHANGED" -eq 0 ]; then
  echo "nothing to remove — this install is not registered anywhere"
  echo "  (hooks pointing at a DIFFERENT model-policy directory are left alone;"
  echo "   re-run with --all to remove those too)"
else
  [ "$DRY" = 1 ] && echo "dry run complete; re-run without --dry-run to apply" \
                 || echo "done in $CHANGED config dir(s). Restart running Claude Code sessions."
fi
echo
echo "This directory and its ledger were left in place:"
echo "  $SHARED_DIR"
