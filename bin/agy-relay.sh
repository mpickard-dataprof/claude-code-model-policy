#!/usr/bin/env bash
# Antigravity offload wrapper. It consumes one gate-issued grant, never flags.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
POLICY="${MODEL_POLICY_POLICY:-$ROOT/policy.json}"
POOL=""; MODEL=""; ACCESS=""; CWD=""
emit() { python3 - "$@" <<'PY'
import json,sys
ok,code,reason=sys.argv[1],int(sys.argv[2]),sys.argv[3]
print(json.dumps({'ok':ok=='true','exit_code':code,'reason':reason or None,'output_file':sys.argv[4] or None,'output_bytes':int(sys.argv[5] or 0),'pool':sys.argv[6] or None,'model':sys.argv[7] or None,'access':sys.argv[8] or None,'cwd':sys.argv[9] or None,'elapsed_s':int(sys.argv[10] or 0),'stderr_tail':sys.argv[11] or None,'teardown':'n/a: no worker was started'}))
PY
}
fail() { emit false "${2:-2}" "$1" "" 0 "$POOL" "$MODEL" "$ACCESS" "$CWD" 0 ""; exit "${2:-2}"; }

[ "$#" -eq 2 ] && [ "$1" = "--grant" ] || fail grant_interface_required
GRANT_ID="$2"
case "$GRANT_ID" in *[!abcdef0123456789]*) fail invalid_grant_id ;; esac
[ "${#GRANT_ID}" -eq 48 ] || fail invalid_grant_id
GRANTS="${MODEL_POLICY_GRANTS:-$ROOT/grants}"; GRANT="$GRANTS/$GRANT_ID.json"
# Validate before consuming; os.replace makes a racing second caller see used.
GRANT_DATA="$(python3 - "$GRANT" "$GRANTS" "$POLICY" <<'PY'
import json,os,sys,time
from datetime import datetime
p,grants,policy_path=sys.argv[1:]
def die(r): print(json.dumps({'error':r})); raise SystemExit
if not os.path.isfile(p): die('grant_already_used' if os.path.exists(p+'.used') else 'grant_missing')
try: g=json.load(open(p)); a=(json.load(open(policy_path)).get('agy') or {})
except Exception: die('grant_invalid')
if any(k not in g for k in ('pool','model','access','cwd','task_path','session_id','created','expires')): die('grant_invalid')
try: expired=datetime.fromisoformat(g['expires'].replace('Z','+00:00')).timestamp()<time.time()
except Exception: die('grant_invalid')
if expired: die('grant_expired')
if g['pool'] not in ('gemini','thirdparty') or g['access'] not in ('read-only','edit'): die('grant_invalid')
if g['model'] not in set(((a.get('pools') or {}).get(g['pool']) or {}).get('byTier',{}).values()): die('grant_invalid')
cwd=os.path.realpath(g['cwd']); task=os.path.realpath(g['task_path']); base=os.path.realpath(grants)+os.sep
if not os.path.isdir(cwd) or not task.startswith(base) or not os.path.isfile(task): die('grant_invalid')
if g['access']=='edit' and (g['pool']!='thirdparty' or '.worktrees' not in cwd.split(os.sep)): die('grant_invalid')
try: os.replace(p,p+'.used')
except FileNotFoundError: die('grant_already_used')
except Exception: die('grant_consume_failed')
g['cwd']=cwd; g['task_path']=task; print(json.dumps(g))
PY
)"
case "$GRANT_DATA" in '{"error":'* ) fail "$(printf '%s' "$GRANT_DATA" | python3 -c 'import json,sys;print(json.load(sys.stdin)["error"])')" ;; esac
field() { printf '%s' "$GRANT_DATA" | python3 -c "import json,sys;print(json.load(sys.stdin)['$1'])"; }
POOL="$(field pool)"; MODEL="$(field model)"; ACCESS="$(field access)"; CWD="$(field cwd)"; TASK="$(field task_path)"
SANDBOX="$(python3 - "$POLICY" <<'PY'
import json,sys
try: print(((json.load(open(sys.argv[1])).get('agy') or {}).get('sandbox') or {}).get('bwrap','/usr/bin/bwrap'))
except Exception: print('')
PY
)"
case "$SANDBOX" in /*) ;; *) fail sandbox_unavailable ;; esac
[ -x "$SANDBOX" ] || fail sandbox_unavailable
BINARY="$(python3 - "$POLICY" <<'PY'
import json,sys
try: print((json.load(open(sys.argv[1])).get('agy') or {}).get('binary') or '$HOME/.local/bin/agy')
except Exception: print('')
PY
)"
case "$BINARY" in '$HOME'/*) BINARY="$HOME/${BINARY#\$HOME/}" ;; esac
case "$BINARY" in /*) ;; *) fail agy_binary_unavailable ;; esac
[ -x "$BINARY" ] || fail agy_binary_unavailable
# Bind the executable's resolved file rather than the configured symlink.  In
# particular, an agy installed below $HOME would otherwise disappear behind the
# home tmpfs below.
BINARY="$(realpath "$BINARY")" || fail agy_binary_unavailable
[ -f "$BINARY" ] || fail agy_binary_unavailable

# Linked worktrees use a .git file which points into the main checkout's common
# git directory.  Re-expose that directory so ordinary read-only git commands
# still work without making the rest of the user's home visible.
GIT_COMMON_DIR="$(git -C "$CWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [ -n "$GIT_COMMON_DIR" ] && [ -d "$GIT_COMMON_DIR" ]; then
  GIT_COMMON_DIR="$(realpath "$GIT_COMMON_DIR")"
else
  GIT_COMMON_DIR=""
fi

OUTBASE="${MODEL_POLICY_AGY_OUTBASE:-${TMPDIR:-/tmp}}"
OUTDIR="$(mktemp -d "$OUTBASE/agy-relay.XXXXXX")" || fail could_not_create_output_dir
PRIVTMP="$(mktemp -d "$OUTBASE/agy-private.XXXXXX")" || fail could_not_create_private_tmp
OUT="$OUTDIR/answer.md"; ERR="$OUTDIR/stderr.log"; PROMPT_FILE="$OUTDIR/prompt.txt"
# agy needs a read_file grant for anything outside its workspace, which headless
# mode auto-denies, so the task is copied into OUTDIR and OUTDIR joins the workspace.
TASK_COPY="$OUTDIR/task.md"; cp "$TASK" "$TASK_COPY" || fail could_not_copy_task
PROMPT="You are a headless delegated subagent. You are already in the project directory; list and read files with your file tools. Do not use find (it is not allowed and aborts the run). Never run tests, builds, installers or scripts: the caller runs them, and any command outside the allowed read-only list aborts your whole run and discards your reply. Read the task file at $TASK_COPY with your file-viewing tool; prefer that tool over a shell. If you use the shell, use only single simple allowed commands (chains only when every command is allowed). Writes outside the permitted directory are blocked by an OS sandbox and will fail. Report failures honestly; never claim a write or command succeeded without its output."
printf '%s\n' "$PROMPT" > "$PROMPT_FILE"

# Broad read-only root first, then make $HOME default-deny.  Every permitted
# home path is deliberately rebound after this tmpfs overlay.
ARGS=(--ro-bind / / --tmpfs "$HOME")
[ -d "$HOME/.gemini" ] && ARGS+=(--bind "$HOME/.gemini" "$HOME/.gemini")
for p in "$HOME/.gemini/antigravity-cli/settings.json" "$HOME/.gemini/GEMINI.md" "$HOME/.gemini/settings.json" "$HOME/.gemini/policies"; do [ -e "$p" ] && ARGS+=(--ro-bind "$p" "$p"); done
# The configured executable may itself live under $HOME.
ARGS+=(--ro-bind "$BINARY" "$BINARY")

# /tmp is private.  Put it before paths which may themselves live under the
# real /tmp, including OUTDIR and a checkout used as CWD.
ARGS+=(--bind "$PRIVTMP" /tmp)
while IFS= read -r hidden; do
  # $HOME is already empty except for the explicit mounts above.  Retain the
  # configurable hide list for paths elsewhere in the filesystem only.
  case "$hidden" in '$HOME'|'$HOME'/*|"$HOME"|"$HOME"/*) continue ;; esac
  if [ -d "$hidden" ]; then ARGS+=(--tmpfs "$hidden"); elif [ -f "$hidden" ]; then ARGS+=(--ro-bind /dev/null "$hidden"); fi
done < <(python3 - "$POLICY" <<'PY'
import json,sys
default=['$HOME/.ssh','$HOME/.gnupg','$HOME/.aws','$HOME/.config/gcloud','$HOME/.docker','$HOME/.kube','$HOME/.netrc']
try:
 h=((json.load(open(sys.argv[1])).get('agy') or {}).get('sandbox') or {}).get('hide',default)
 for x in h:
  if isinstance(x,str): print(x)
except Exception: pass
PY
)
ARGS+=(--bind "$OUTDIR" "$OUTDIR")
if [ "$ACCESS" = edit ]; then ARGS+=(--bind "$CWD" "$CWD"); else ARGS+=(--ro-bind "$CWD" "$CWD"); fi
[ -n "$GIT_COMMON_DIR" ] && ARGS+=(--ro-bind "$GIT_COMMON_DIR" "$GIT_COMMON_DIR")
ARGS+=(--dev /dev --proc /proc --die-with-parent --chdir "$CWD" --)
MODE=(); [ "$ACCESS" = edit ] && MODE=(--mode accept-edits)
SUP="$(python3 "$ROOT/bin/codex-supervise.py" --command 900 "$OUT" "$ERR" "$OUT" "$PROMPT_FILE" "$MODEL" "$CWD" -- "$SANDBOX" "${ARGS[@]}" "$BINARY" -p "$PROMPT" --add-dir "$OUTDIR" --model "$MODEL" --print-timeout 900s "${MODE[@]}")"
python3 - "$SUP" "$POOL" "$MODEL" "$ACCESS" "$CWD" "$OUT" "$ERR" <<'PY'
import json,os,re,sys
try: result=json.loads(sys.argv[1])
except Exception: result={'ok':False,'exit_code':2,'reason':'supervisor produced invalid JSON'}
pool,model,access,cwd,out,err=sys.argv[2:]
# The supervisor already marks an empty answer as failed; name the real cause when
# agy says a headless permission prompt was auto-denied.
try:
 stderr=open(err,errors='replace').read()
 if os.path.getsize(out)==0 and any(x.startswith('jetski: no output produced') for x in stderr.splitlines()):
  m=re.search(r'"([a-z_]+)" permission',stderr)
  result['ok']=False; result['reason']='agy_permission_denied:'+(m.group(1) if m else 'unknown')
  # An edit run can be cut off after it has already changed files.
  if access=='edit': result['edits_may_exist']=True; result['check']='git -C %s status --short' % cwd
except Exception: pass
result.update({'pool':pool,'model':model,'access':access,'cwd':cwd}); result.pop('effort',None); result.pop('sandbox',None)
print(json.dumps(result)); sys.exit(0 if result.get('ok') else 1)
PY
exit $?
