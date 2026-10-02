#!/usr/bin/env bash
# Antigravity offload wrapper. It consumes one gate-issued grant, never flags.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
POLICY="${MODEL_POLICY_POLICY:-$ROOT/policy.json}"
POOL=""; MODEL=""; ACCESS=""; CWD=""
emit() { python3 - "$@" <<'PY'
import json,sys
ok,code,reason=sys.argv[1],int(sys.argv[2]),sys.argv[3]
print(json.dumps({'ok':ok=='true','exit_code':code,'reason':reason or None,'output_file':sys.argv[4] or None,'output_bytes':int(sys.argv[5] or 0),'truncated':False,'pool':sys.argv[6] or None,'model':sys.argv[7] or None,'access':sys.argv[8] or None,'cwd':sys.argv[9] or None,'elapsed_s':int(sys.argv[10] or 0),'stderr_tail':sys.argv[11] or None,'teardown':'n/a: no worker was started'}))
print('--- AGY-ANSWER ---')
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
import json,os,sys,time,subprocess,stat
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
home=os.path.realpath(os.path.expanduser('~'))
try: secret_child=any(n == '.gemini' or n == '.ssh' or n == '.claude' or n.startswith('.claude') for n in os.listdir(cwd))
except Exception: secret_child=True
# Do this by components, not string prefixes: '/' + os.sep is '//', which made
# the filesystem root skip the old ancestor-of-home check.
cwd_parts=[p for p in cwd.split(os.sep) if p]
home_parts=[p for p in home.split(os.sep) if p]
is_home_ancestor=(len(cwd_parts)<=len(home_parts) and cwd_parts==home_parts[:len(cwd_parts)])
if cwd == os.sep or len(cwd_parts)<2 or is_home_ancestor or secret_child: die('cwd_not_allowed')
if g['access']=='edit':
 if g['pool']!='thirdparty' or os.path.basename(os.path.dirname(cwd))!='.worktrees': die('grant_invalid')
 git=os.path.join(cwd,'.git')
 try: git_mode=os.lstat(git).st_mode
 except Exception: die('grant_invalid')
 if not (stat.S_ISREG(git_mode) or stat.S_ISDIR(git_mode)): die('grant_invalid')
 try:
  top=os.path.realpath(subprocess.check_output(['git','-C',cwd,'rev-parse','--show-toplevel'],stderr=subprocess.DEVNULL,text=True).strip())
  if top != cwd: die('grant_invalid')
 except SystemExit: raise
 except Exception: die('grant_invalid')
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
TASK_IN_BOX="/relay/task.md"
PROMPT="You are a headless delegated subagent. You are already in the project directory; list and read files with your file tools. Do not use find (it is not allowed and aborts the run). Never run tests, builds, installers or scripts: the caller runs them, and any command outside the allowed read-only list aborts your whole run and discards your reply. Read the task file at $TASK_IN_BOX with your file-viewing tool; prefer that tool over a shell. If you use the shell, use only single simple allowed commands (chains only when every command is allowed). Writes outside the permitted directory are blocked by an OS sandbox and will fail. Report failures honestly; never claim a write or command succeeded without its output."
printf '%s\n' "$PROMPT" > "$PROMPT_FILE"

# A tmpfs root lets us create /workspace before any readonly host mount. Only
# the runtime system directories needed by the CLI are exposed below.
ARGS=(--tmpfs / --dir /workspace --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib64 /lib64)
# Never expose /run: it contains per-user IPC sockets which escape the sandbox.
# /etc remains readonly for ordinary runtime configuration. Its resolver is
# commonly an absolute symlink into /run, so expose only that resolved file at
# both the target path and /etc/resolv.conf, never the containing directory.
for p in /usr /etc /opt; do [ -e "$p" ] && ARGS+=(--ro-bind "$p" "$p"); done
RESOLV_TARGET="$(realpath /etc/resolv.conf 2>/dev/null || true)"
if [ -n "$RESOLV_TARGET" ] && [ -f "$RESOLV_TARGET" ]; then
  ensure_resolv_parents() {
    local p="$1" parent part built=""
    parent="${p%/*}"; [ -n "$parent" ] || return
    IFS=/ read -r -a pieces <<< "${parent#/}"
    for part in "${pieces[@]}"; do [ -n "$part" ] || continue; built="$built/$part"; ARGS+=(--dir "$built"); done
  }
  ensure_resolv_parents "$RESOLV_TARGET"
  ARGS+=(--ro-bind "$RESOLV_TARGET" "$RESOLV_TARGET" --ro-bind "$RESOLV_TARGET" /etc/resolv.conf)
fi
ARGS+=(--dir /home --dir "$HOME" --tmpfs "$HOME")

# Make parent paths in the tmpfs root before a bind/hide at an absolute host
# pathname. This is needed for Git's linked-worktree metadata and nested hide
# entries such as ~/.local/share/keyrings.
ensure_box_parents() {
  local p="$1" parent part built=""
  parent="${p%/*}"; [ -n "$parent" ] || return
  IFS=/ read -r -a pieces <<< "${parent#/}"
  for part in "${pieces[@]}"; do
    [ -n "$part" ] || continue
    built="$built/$part"
    ARGS+=(--dir "$built")
  done
}

# /tmp is private.  Put it before paths which may themselves live under the
# real /tmp, including OUTDIR and a checkout used as CWD.
ARGS+=(--bind "$PRIVTMP" /tmp)
# The captured realpath is intentionally mounted at a fixed destination: a
# same-UID rename cannot turn the in-box workspace into a different pathname.
if [ "$ACCESS" = edit ]; then ARGS+=(--bind "$CWD" /workspace); else ARGS+=(--ro-bind "$CWD" /workspace); fi
if [ -n "$GIT_COMMON_DIR" ]; then ensure_box_parents "$GIT_COMMON_DIR"; ARGS+=(--ro-bind "$GIT_COMMON_DIR" "$GIT_COMMON_DIR"); fi
if [ "$ACCESS" = edit ]; then ARGS+=(--ro-bind "$CWD/.git" /workspace/.git); fi

# An edit worker may change source files, but never leave host-executed editor,
# agent, CI, or shell configuration behind. Directories are private tmpfses;
# files are rebound readonly (or /dev/null when absent) so they cannot be made.
if [ "$ACCESS" = edit ]; then
  while IFS=$'\t' read -r kind name; do
    case "$name" in ''|/*|*'..'*) continue ;; esac
    target="/workspace/$name"; source="$CWD/$name"
    if [ "$kind" = D ]; then
      ARGS+=(--tmpfs "$target")
    elif [ "$kind" = F ]; then
      if [ -f "$source" ]; then ARGS+=(--ro-bind "$source" "$target"); else ARGS+=(--ro-bind /dev/null "$target"); fi
    fi
  done < <(python3 - "$POLICY" <<'PY'
import json,sys
default={'dirs':['.claude','.vscode','.idea','.github/workflows','.husky'],
         'files':['.mcp.json','.envrc','CLAUDE.md','CLAUDE.local.md','AGENTS.md','GEMINI.md','.claude.json']}
try:
 s=((json.load(open(sys.argv[1])).get('agy') or {}).get('sandbox') or {})
 m=s.get('editMask',default)
 if isinstance(m,list):
  # List form is supported for simple custom policies; known directory entries
  # retain directory semantics and all other entries are file masks.
  dirs=set(default['dirs'])
  m={'dirs':[x for x in m if x in dirs], 'files':[x for x in m if x not in dirs]}
 for x in m.get('dirs',[]):
  if isinstance(x,str): print('D\t'+x)
 for x in m.get('files',[]):
  if isinstance(x,str): print('F\t'+x)
except Exception: pass
PY
)
fi

# Apply hiding only after cwd/git binds. In particular, never skip a $HOME path:
# a future unsafe bind cannot accidentally punch through this deny list.
while IFS= read -r hidden; do
  hidden="${hidden/\$HOME/$HOME}"
  for target in $hidden; do
    ensure_box_parents "$target"
    if [ -d "$target" ]; then ARGS+=(--tmpfs "$target"); elif [ -f "$target" ]; then ARGS+=(--ro-bind /dev/null "$target"); fi
  done
done < <(python3 - "$POLICY" <<'PY'
import json,sys
default=['$HOME/.ssh','$HOME/.gnupg','$HOME/.aws','$HOME/.claude*','$HOME/.config','$HOME/.local/share/keyrings','$HOME/.docker','$HOME/.kube','$HOME/.netrc']
try:
 h=((json.load(open(sys.argv[1])).get('agy') or {}).get('sandbox') or {}).get('hide',default)
 for x in h:
  if isinstance(x,str): print(x)
except Exception: pass
PY
)

# Gemini configuration is code-adjacent input, so the whole tree stays readonly.
# Only the CLI's observed runtime state is writable, and each target is rebound
# after the readonly parent. Create the state targets outside the box first.
GEMINI="$HOME/.gemini"; AGY_STATE="$GEMINI/antigravity-cli"
if [ -d "$GEMINI" ]; then
  mkdir -p "$AGY_STATE"/{brain,conversations,cache,log,implicit,annotations,crashes,presence} 2>/dev/null || true
  for f in history.jsonl conversation_summaries.db jetski_state.pbtxt jetbox_summaries_proto.pb last_check.timestamp; do
    [ -e "$AGY_STATE/$f" ] || : > "$AGY_STATE/$f" 2>/dev/null || true
  done
  ensure_box_parents "$GEMINI"
  ARGS+=(--ro-bind "$GEMINI" "$GEMINI")
  for p in brain conversations cache log implicit annotations crashes presence history.jsonl conversation_summaries.db jetski_state.pbtxt jetbox_summaries_proto.pb last_check.timestamp; do
    [ -e "$AGY_STATE/$p" ] && ARGS+=(--bind "$AGY_STATE/$p" "$AGY_STATE/$p")
  done
fi
# The configured executable may itself live under $HOME.
ARGS+=(--ro-bind "$BINARY" /agy)
# /relay contains task input only. Worker stdout is captured through the
# supervisor's already-open host FD, so a worker cannot replace answer.md with
# a symlink that the host later reopens by name.
ARGS+=(--dir /relay --ro-bind "$TASK_COPY" /relay/task.md)
ARGS+=(--unshare-ipc --unshare-pid --new-session --unshare-uts --clearenv)
ARGS+=(--setenv HOME "$HOME" --setenv PATH "${PATH:-/usr/bin:/bin}" --setenv LANG "${LANG:-C.UTF-8}" --setenv TERM "${TERM:-dumb}" --setenv TZ "${TZ:-UTC}")
ARGS+=(--dev /dev --proc /proc --die-with-parent --chdir /workspace --)
# git keeps a worktree's history in the main repo's common dir; models read it
# directly, and agy needs it in the workspace or the read is auto-denied headless.
GIT_ADD_DIR=(); [ -n "$GIT_COMMON_DIR" ] && GIT_ADD_DIR=(--add-dir "$GIT_COMMON_DIR")
MODE=(); [ "$ACCESS" = edit ] && MODE=(--mode accept-edits)
SOURCE_STAT="$(stat -Lc '%d:%i' "$CWD" 2>/dev/null || true)"
SUPFILE="$OUTDIR/supervisor.json"
python3 "$ROOT/bin/codex-supervise.py" --command 900 "$OUT" "$ERR" "$OUT" "$PROMPT_FILE" "$MODEL" "$CWD" -- "$SANDBOX" "${ARGS[@]}" /agy -p "$PROMPT" --add-dir /relay "${GIT_ADD_DIR[@]}" --model "$MODEL" --print-timeout 900s "${MODE[@]}" > "$SUPFILE" &
SUP_PID=$!
# Re-check immediately after launch. This narrows the same-UID rename window;
# an attacker already executing as this UID remains outside this wrapper's scope.
sleep 0.05
FORCED_REASON=""
if [ "$SOURCE_STAT" != "$(stat -Lc '%d:%i' "$CWD" 2>/dev/null || true)" ]; then
  FORCED_REASON="cwd_changed"
  kill "$SUP_PID" 2>/dev/null || true
fi
wait "$SUP_PID" || true
SUP="$(python3 - "$SUPFILE" <<'PY'
import os,stat,sys
try:
 fd=os.open(sys.argv[1],os.O_RDONLY|os.O_NOFOLLOW)
 try:
  if not stat.S_ISREG(os.fstat(fd).st_mode): raise OSError('not a regular file')
  chunks=[]
  while True:
   b=os.read(fd,65536)
   if not b: break
   chunks.append(b)
  sys.stdout.buffer.write(b''.join(chunks))
 finally: os.close(fd)
except Exception: pass
PY
)"
NESTED_GIT=""
[ "$ACCESS" = edit ] && NESTED_GIT="$(find "$CWD" -mindepth 2 -name .git -print -quit 2>/dev/null || true)"
python3 - "$SUP" "$POOL" "$MODEL" "$ACCESS" "$CWD" "$OUT" "$ERR" "$FORCED_REASON" "$NESTED_GIT" <<'PY'
import json,os,re,stat,sys
def safe_read(path):
 try:
  fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
  try:
   st=os.fstat(fd)
   if not stat.S_ISREG(st.st_mode): return b'',0
   chunks=[]
   while True:
    b=os.read(fd,65536)
    if not b: break
    chunks.append(b)
   return b''.join(chunks),st.st_size
  finally: os.close(fd)
 except Exception: return b'',0
try: result=json.loads(sys.argv[1])
except Exception: result={'ok':False,'exit_code':2,'reason':'supervisor produced invalid JSON'}
pool,model,access,cwd,out,err,forced,nested=sys.argv[2:]
# The supervisor already marks an empty answer as failed; name the real cause when
# agy says a headless permission prompt was auto-denied.
try:
 stderr_bytes,_=safe_read(err); stderr=stderr_bytes.decode('utf-8','replace')
 answer_bytes,answer_size=safe_read(out)
 if answer_size==0 and any(x.startswith('jetski: no output produced') for x in stderr.splitlines()):
  m=re.search(r'"([a-z_]+)" permission',stderr)
  result['ok']=False; result['reason']='agy_permission_denied:'+(m.group(1) if m else 'unknown')
  # An edit run can be cut off after it has already changed files.
  if access=='edit': result['edits_may_exist']=True; result['check']='git -C %s status --short' % cwd
except Exception: pass
result.update({'pool':pool,'model':model,'access':access,'cwd':cwd}); result.pop('effort',None); result.pop('sandbox',None)
if forced:
 result.update({'ok':False,'reason':forced})
if nested:
 result.update({'ok':False,'reason':'nested_git_created'})
cap=200*1024
answer,answer_size=safe_read(out); truncated=answer_size>cap
result['truncated']=truncated
print(json.dumps(result)); sys.stdout.flush()
print('--- AGY-ANSWER ---'); sys.stdout.flush()
if result.get('ok'):
 sys.stdout.buffer.write(answer[:cap])
 if truncated: sys.stdout.buffer.write(b'\n\n[AGY answer truncated at 200 KiB]\n')
 sys.stdout.flush()
sys.exit(0 if result.get('ok') else 1)
PY
exit $?
