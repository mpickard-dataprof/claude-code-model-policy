#!/usr/bin/env bash
# Install tiered subagent model selection into every Claude config dir on this machine.
#
# Idempotent and safe to re-run. Backs up each settings.json before touching it.
# Portable to macOS and Linux (no GNU-only flags).
#
#   ./install.sh              install / repair every config dir found
#   ./install.sh --dry-run    show what would be targeted, change nothing
#   ./install.sh ~/.claude-x  install into specific dirs (for ones not yet auto-detected)

set -euo pipefail

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

SHARED_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$SHARED_DIR/hooks"
SKILL_DIR="$SHARED_DIR/skill"
AGENTS_DIR="$SHARED_DIR/agents"

echo "model-policy installer"
echo "  source: $SHARED_DIR"

# Same resolution order as hooks/run.sh. nvm only populates PATH in interactive
# shells, so a plain `command -v node` fails over ssh even when node is installed.
find_node() {
  if command -v node >/dev/null 2>&1; then command -v node; return 0; fi
  for c in /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node /snap/bin/node; do
    [ -x "$c" ] && { echo "$c"; return 0; }
  done
  # Glob directly rather than $(ls ... | tail -1): unquoted command substitution
  # word-splits on IFS, so any space in $HOME or the nvm path yields a fragment.
  nvm_node=""
  for c in "$HOME"/.nvm/versions/node/*/bin/node; do
    [ -x "$c" ] && nvm_node="$c"
  done
  [ -n "$nvm_node" ] && { echo "$nvm_node"; return 0; }
  return 1
}

NODE_BIN="$(find_node)" || { echo "  ! node not found anywhere — install Node 18+ first"; exit 1; }
NODE_VER="$("$NODE_BIN" --version 2>/dev/null || echo v0)"
echo "  node:   $NODE_VER ($NODE_BIN)"
# The hooks use ESM, optional chaining and logical-assignment (`??=`). On older
# Node these fail as syntax errors at load time, which reads as "the hook silently
# does nothing" rather than as a version problem.
NODE_MAJOR="$(printf '%s' "$NODE_VER" | sed 's/^v//; s/\..*//')"
case "$NODE_MAJOR" in
  ''|*[!0-9]*) echo "  ! could not parse node version '$NODE_VER' — continuing anyway" ;;
  *) if [ "$NODE_MAJOR" -lt 18 ]; then
       echo "  ! node $NODE_VER is too old. These hooks need Node 18 or newer."
       exit 1
     fi ;;
esac
echo

# --- discover config dirs -----------------------------------------------------
# A Claude Code config dir is ~/.claude* containing a Claude Code runtime artifact
# (projects/, sessions/, or history.jsonl). Testing for settings.json alone is not
# enough: plugin data dirs such as ~/.claude-mem ship their own settings.json and
# would otherwise be mistaken for config dirs.
# ~/.claude is always accepted — it is the canonical default and may be empty on a
# fresh machine. The directory this installer lives in is never a target, however it
# happens to be named.
is_config_dir() {
  local d="$1"
  [ -d "$d" ] || return 1
  # Never treat our own install directory (or a parent of it) as a config dir.
  case "$SHARED_DIR/" in "$d"/*) return 1 ;; esac
  [ "$d" = "$HOME/.claude" ] && return 0
  [ -d "$d/projects" ] || [ -d "$d/sessions" ] || [ -f "$d/history.jsonl" ]
}

# A scalar counter alongside the array: `${#arr[@]}` on an EMPTY array under
# `set -u` is an unbound-variable error on bash < 4.4, which is macOS's default
# /bin/bash 3.2. The count is checked before any array expansion happens.
CONFIG_DIRS=()
CONFIG_COUNT=0
add_dir() { CONFIG_DIRS+=("$1"); CONFIG_COUNT=$((CONFIG_COUNT + 1)); }

if [ "$#" -gt 0 ] && [ "${1:-}" != "--dry-run" ]; then
  # Explicit targets, e.g. a config dir that does not exist yet on a new machine.
  for d in "$@"; do
    if [ -d "$d" ]; then add_dir "$d"; else echo "  ! not a directory, skipping: $d"; fi
  done
else
  # CLAUDE_CONFIG_DIR may point outside ~/.claude*, in which case the glob below
  # finds nothing and the install silently does nothing at all.
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ -d "$CLAUDE_CONFIG_DIR" ]; then
    add_dir "$CLAUDE_CONFIG_DIR"
    echo "  using CLAUDE_CONFIG_DIR: $CLAUDE_CONFIG_DIR"
  fi
  for d in "$HOME"/.claude*; do
    # Skip a dir already added via CLAUDE_CONFIG_DIR.
    if [ "${CLAUDE_CONFIG_DIR:-}" = "$d" ]; then continue; fi
    if is_config_dir "$d"; then add_dir "$d"; fi
  done
fi

if [ "$CONFIG_COUNT" -eq 0 ]; then
  echo "  ! no Claude config dirs found under $HOME — nothing to do"
  exit 1
fi

echo "config dirs found: $CONFIG_COUNT"
for d in "${CONFIG_DIRS[@]}"; do echo "  - $d"; done
echo

if [ "$DRY_RUN" = "1" ]; then
  echo "(dry run — no changes made)"
  exit 0
fi

# --- make hooks executable ----------------------------------------------------
chmod +x "$HOOKS_DIR"/*.mjs "$HOOKS_DIR"/run.sh
echo "hooks made executable"
echo

# --- register hooks + link the skill -----------------------------------------
echo "registering hooks:"
FAILED=0
AGENTS_LINKED=0
AGENTS_SKIPPED=0
for d in "${CONFIG_DIRS[@]}"; do
  "$NODE_BIN" "$SHARED_DIR/install-merge.mjs" "$d" "$HOOKS_DIR" || FAILED=1
  mkdir -p "$d/skills"
  # -n so a re-run replaces the link instead of nesting inside it
  ln -sfn "$SKILL_DIR" "$d/skills/model-policy-tune"

  # Agent definitions carry model AND effort together. Linked per file rather
  # than as a whole directory, so any agents already in that config dir survive.
  if [ -d "$AGENTS_DIR" ]; then
    mkdir -p "$d/agents"
    for a in "$AGENTS_DIR"/*.md; do
      [ -f "$a" ] || continue
      dest="$d/agents/$(basename "$a")"
      # Never clobber an agent the user wrote themselves. Only create the link, or
      # refresh one we previously created.
      if [ -e "$dest" ] && [ ! -L "$dest" ]; then
        echo "  ! $dest exists and is not our symlink — left untouched"
        AGENTS_SKIPPED=$((AGENTS_SKIPPED + 1))
        continue
      fi
      ln -sfn "$a" "$dest"
      AGENTS_LINKED=$((AGENTS_LINKED + 1))
    done
  fi
done
echo
echo "skill linked into each config dir as: model-policy-tune"
# Report what was actually linked, not what exists in AGENTS_DIR — the loop above
# skips any destination the user owns, and claiming those as linked would be a lie.
if [ "$AGENTS_SKIPPED" -gt 0 ]; then
  echo "agent links created: $AGENTS_LINKED  (skipped $AGENTS_SKIPPED pre-existing non-symlink file(s))"
  echo
  echo "  ! Those skipped files mean EFFORT TIERING IS OFF for the affected agent name."
  echo "    The gate only redirects to an agent it can prove is ours, so a hand-written"
  echo "    scout.md or worker.md silently disables the redirect rather than overriding it."
  echo "    Either rename your own agent, or set redirect.byTier in policy.json to a name"
  echo "    that does not collide."
else
  echo "agent links created: $AGENTS_LINKED across $CONFIG_COUNT config dir(s)"
fi

# --- which tiers can this account actually use? ------------------------------
# Routing to a model the account cannot run fails the spawn outright — a fail-open
# violation caused purely by configuration. Entitlement is not queryable, but the
# transcripts record every model that has actually run, which is real evidence.
# Absence is not proof, so this only ever pre-fills a value the user can edit.
if [ -z "${MODEL_POLICY_SKIP_TIER_PROBE:-}" ]; then
  PROBE="$("$NODE_BIN" -e '
    const fs = require("fs"), path = require("path"), os = require("os");
    const seen = new Set();
    const roots = [];
    try {
      for (const d of fs.readdirSync(os.homedir())) {
        if (d.startsWith(".claude")) roots.push(path.join(os.homedir(), d, "projects"));
      }
    } catch {}
    let scanned = 0;
    const walk = (dir, depth) => {
      if (depth > 3 || scanned > 400) return;
      let ents = [];
      try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
      for (const e of ents) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) walk(p, depth + 1);
        else if (e.name.endsWith(".jsonl")) {
          scanned++;
          try {
            // Tail only: enough to see which models this account runs.
            const fd = fs.openSync(p, "r");
            const size = fs.statSync(p).size;
            const len = Math.min(size, 131072);
            const buf = Buffer.alloc(len);
            fs.readSync(fd, buf, 0, len, Math.max(0, size - len));
            fs.closeSync(fd);
            for (const m of buf.toString("utf8").matchAll(/"model":"([a-z0-9.\-]+)"/g)) {
              const v = m[1].toLowerCase();
              if (v.includes("haiku")) seen.add("haiku");
              else if (v.includes("sonnet")) seen.add("sonnet");
              else if (v.includes("opus")) seen.add("opus");
              else if (v.includes("fable") || v.includes("mythos")) seen.add("fable");
            }
          } catch {}
        }
      }
    };
    for (const r of roots) walk(r, 0);
    process.stdout.write(JSON.stringify({ seen: [...seen], scanned }));
  ' 2>/dev/null || echo "")"

  if [ -n "$PROBE" ]; then
    echo
    "$NODE_BIN" -e '
      const fs = require("fs");
      const probe = JSON.parse(process.argv[1]);
      const policyPath = process.argv[2];
      if (probe.scanned === 0) {
        console.log("tier probe: no transcripts yet — leaving disabledTiers as configured");
        process.exit(0);
      }
      console.log(`tier probe: scanned ${probe.scanned} transcript(s); models observed: ${probe.seen.sort().join(", ") || "none"}`);
      let raw, policy;
      try { raw = fs.readFileSync(policyPath, "utf8"); policy = JSON.parse(raw); } catch { process.exit(0); }
      // Only ever ADD to disabledTiers, and only for tiers never observed. Never
      // re-enable something the user disabled by hand.
      const already = new Set(Array.isArray(policy.disabledTiers) ? policy.disabledTiers : []);
      const before = already.size;
      for (const t of policy.tierOrder || []) {
        // haiku/sonnet/opus are universally available; only gate the premium tier.
        if (t === "fable" && !probe.seen.includes("fable")) already.add(t);
      }
      if (already.size === before) {
        console.log("  all configured tiers look usable — no change");
        process.exit(0);
      }
      const list = [...already];
      const updated = raw.replace(/"disabledTiers"\s*:\s*\[[^\]]*\]/, `"disabledTiers": ${JSON.stringify(list)}`);
      if (updated === raw) { console.log("  could not update policy.json automatically"); process.exit(0); }
      try { JSON.parse(updated); } catch { console.log("  edit would corrupt policy.json — skipped"); process.exit(0); }
      fs.writeFileSync(policyPath, updated);
      console.log(`  set disabledTiers = ${JSON.stringify(list)} (never seen in your transcripts)`);
      console.log("  those tiers now fall back to the next cheaper one. Edit policy.json if wrong.");
    ' "$PROBE" "$SHARED_DIR/policy.json"
  fi
fi

# --- warn about the one thing that silently disables all of this -------------
if [ -n "${CLAUDE_CODE_SUBAGENT_MODEL:-}" ]; then
  echo
  echo "  ! WARNING: CLAUDE_CODE_SUBAGENT_MODEL is set to '$CLAUDE_CODE_SUBAGENT_MODEL'."
  echo "    It outranks per-invocation model selection, so tiered routing will not apply."
  echo "    Unset it to enable this policy."
fi

echo
if [ "$FAILED" = "1" ]; then
  echo "done, with errors above — check any skipped config dir"
  exit 1
fi
echo "done. Restart any running Claude Code sessions to pick up the hooks."
echo "Ledger will accumulate at: $SHARED_DIR/ledger.jsonl"
