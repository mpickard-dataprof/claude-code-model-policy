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
fail_edit_leftovers() { python3 - "$1" "$POOL" "$MODEL" "$ACCESS" "$CWD" <<'PY'
import json,sys
leftovers=json.loads(sys.argv[1])
print(json.dumps({'ok':False,'exit_code':2,'reason':'edit_leftovers_present','output_file':None,'output_bytes':0,'truncated':False,'pool':sys.argv[2] or None,'model':sys.argv[3] or None,'access':sys.argv[4] or None,'cwd':sys.argv[5] or None,'elapsed_s':0,'stderr_tail':None,'teardown':'n/a: no worker was started','leftovers':leftovers}))
print('--- AGY-ANSWER ---')
PY
exit 2
}

[ "$#" -eq 2 ] && [ "$1" = "--grant" ] || fail grant_interface_required
GRANT_ID="$2"
case "$GRANT_ID" in *[!abcdef0123456789]*) fail invalid_grant_id ;; esac
[ "${#GRANT_ID}" -eq 48 ] || fail invalid_grant_id
GRANTS="${MODEL_POLICY_GRANTS:-$ROOT/grants}"; GRANT="$GRANTS/$GRANT_ID.json"
# Validate before consuming; os.replace makes a racing second caller see used.
GRANT_DATA="$(python3 - "$GRANT" "$GRANTS" "$POLICY" "$ROOT" <<'PY'
import json,os,sys,time,subprocess,stat
from datetime import datetime
p,grants,policy_path,root=sys.argv[1:]
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
if g['access']=='edit' and a.get('editEnabled') is not True: die('edit_disabled')
if g['access']=='edit':
 if g['pool']!='thirdparty' or os.path.basename(os.path.dirname(cwd))!='.worktrees': die('grant_invalid')
 git=os.path.join(cwd,'.git')
 try: git_mode=os.lstat(git).st_mode
 except Exception: die('grant_invalid')
 if not (stat.S_ISREG(git_mode) or stat.S_ISDIR(git_mode)): die('grant_invalid')
 try:
  chain=json.loads(subprocess.check_output([sys.executable,os.path.join(root,'bin','agy-git-chain.py'),cwd],text=True))
  if chain.get('valid') is not True: die('grant_invalid')
 except SystemExit: raise
 except Exception: die('grant_invalid')
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
GIT_COMMON_DIR="$(python3 "$ROOT/bin/agy-git-chain.py" "$CWD" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("common", ""))' 2>/dev/null || true)"

OUTBASE="${MODEL_POLICY_AGY_OUTBASE:-${TMPDIR:-/tmp}}"
OUTDIR="$(mktemp -d "$OUTBASE/agy-relay.XXXXXX")" || fail could_not_create_output_dir
PRIVTMP="$(mktemp -d "$OUTBASE/agy-private.XXXXXX")" || fail could_not_create_private_tmp
COPYDIR=""
cleanup_private() { [ -z "$COPYDIR" ] || rm -rf -- "$COPYDIR"; rm -rf -- "$PRIVTMP"; }
SUP_PID=""
interrupted=0
interrupt_worker() {
  [ "$interrupted" = 1 ] && exit 130
  interrupted=1
  trap '' INT TERM HUP
  if [ -n "$SUP_PID" ]; then
    # A supervisor that owns its own process group gets the group signal; most
    # shells leave background jobs in ours, where the PID-only fallback avoids
    # signalling the relay itself.
    if [ "$(ps -o pgid= -p "$SUP_PID" 2>/dev/null | tr -d ' ')" = "$SUP_PID" ]; then kill -TERM -- "-$SUP_PID" 2>/dev/null || true; else kill -TERM "$SUP_PID" 2>/dev/null || true; fi
    wait "$SUP_PID" 2>/dev/null || true
  fi
  cleanup_private
  emit false 130 interrupted "" 0 "$POOL" "$MODEL" "$ACCESS" "$CWD" 0 ""
  exit 130
}
trap cleanup_private EXIT
trap interrupt_worker INT TERM HUP
OUT="$OUTDIR/answer.md"; ERR="$OUTDIR/stderr.log"; PROMPT_FILE="$OUTDIR/prompt.txt"
# agy needs a read_file grant for anything outside its workspace, which headless
# mode auto-denies, so the task is copied into OUTDIR and OUTDIR joins the workspace.
TASK_COPY="$OUTDIR/task.md"; cp "$TASK" "$TASK_COPY" || fail could_not_copy_task
TASK_IN_BOX="/relay/task.md"
PROMPT="You are a headless delegated subagent. You are already in the project directory; list and read files with your file tools. Do not use find (it is not allowed and aborts the run). Never run tests, builds, installers or scripts: the caller runs them, and any command outside the allowed read-only list aborts your whole run and discards your reply. Read the task file at $TASK_IN_BOX with your file-viewing tool; prefer that tool over a shell. If you use the shell, use only single simple allowed commands (chains only when every command is allowed). Writes outside the permitted directory are blocked by an OS sandbox and will fail. Report failures honestly; never claim a write or command succeeded without its output."
printf '%s\n' "$PROMPT" > "$PROMPT_FILE"

# Edit workers never see the real checkout writable.  Make a private, ordinary
# file copy from Git's tracked + unignored view, then copy back only a validated
# manifest delta after the worker is gone.
# Never under PRIVTMP: that is the box's writable /tmp. OUTDIR is not bound in.
BASELINE="$OUTDIR/edit-baseline.json"
if [ "$ACCESS" = edit ]; then
  EDIT_LEFTOVERS="$(python3 - "$CWD" <<'PY'
import json,os,sys
out=[]
for root,ds,fs in os.walk(sys.argv[1],followlinks=False):
 if '.git' in ds: ds.remove('.git')
 for n in fs:
  if n.startswith(('.agy-stage-','.agy-bak-')): out.append(os.path.relpath(os.path.join(root,n),sys.argv[1]))
print(json.dumps(sorted(out)))
PY
)"
  [ "$EDIT_LEFTOVERS" = '[]' ] || fail_edit_leftovers "$EDIT_LEFTOVERS"
  COPYDIR="$(mktemp -d "$OUTBASE/agy-edit.XXXXXX")" || fail could_not_create_edit_copy
  python3 - "$CWD" "$COPYDIR" "$BASELINE" <<'PY' || fail could_not_copy_edit_workspace
import hashlib,json,os,stat,subprocess,sys
src,dst,manifest=sys.argv[1:]
def bad(): raise RuntimeError('unsafe git path')
def digest(fd):
 h=hashlib.sha256()
 while True:
  b=os.read(fd,65536)
  if not b: return h.hexdigest()
  h.update(b)
paths=subprocess.check_output(['git','-C',src,'ls-files','-z','-c','-o','--exclude-standard'])
base={}
for raw in paths.split(b'\0'):
 if not raw: continue
 rel=os.fsdecode(raw)
 parts=rel.split('/')
 if os.path.isabs(rel) or not rel or any(x in ('','.', '..') for x in parts): bad()
 full=os.path.join(src,rel)
 try: st=os.lstat(full)
 except FileNotFoundError: continue
 if not stat.S_ISREG(st.st_mode): continue
 if os.path.commonpath([src,os.path.realpath(full)]) != src: bad()
 target=os.path.join(dst,rel); os.makedirs(os.path.dirname(target),mode=0o700,exist_ok=True)
 infd=os.open(full,os.O_RDONLY|os.O_NOFOLLOW)
 try:
  fst=os.fstat(infd)
  if not stat.S_ISREG(fst.st_mode): continue
  outfd=os.open(target,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
  try:
   h=hashlib.sha256()
   while True:
    b=os.read(infd,65536)
    if not b: break
    h.update(b); os.write(outfd,b)
   os.fsync(outfd)
  finally: os.close(outfd)
 finally: os.close(infd)
 mode=stat.S_IMODE(fst.st_mode)
 # The private copy is writable by this run even when a host file is readonly;
 # retain only owner permissions, including executability when it had any.
 os.chmod(target,0o600 | (0o100 if mode & 0o111 else 0))
 base[rel]={'sha256':h.hexdigest(),'mode':mode,'host_sha256':h.hexdigest()}
with open(manifest,'w',encoding='utf-8') as f: json.dump(base,f,sort_keys=True)
PY
  # bwrap needs a destination with the same kind as the readonly host .git
  # overlay. It is excluded from the manifest and is never copied back.
  if [ -d "$CWD/.git" ] && [ ! -L "$CWD/.git" ]; then
    mkdir -p "$COPYDIR/.git" || fail could_not_prepare_edit_git_mount
  else
    : > "$COPYDIR/.git" || fail could_not_prepare_edit_git_mount
  fi
fi

# A repository config and FETCH_HEAD can contain remote credentials.  Keep the
# Git shape needed for read-only history commands, but bind only a per-run
# allowlisted config and empty FETCH_HEAD files into the box.
SANITIZED_GIT_DIR="$OUTDIR/git-sanitized"; mkdir -p "$SANITIZED_GIT_DIR" || fail could_not_create_output_dir
sanitize_git_config() { python3 - "$1" "$2" <<'PY'
import os,re,subprocess,sys
src,dst=sys.argv[1:]
open(dst,'w').close()
if not os.path.isfile(src): raise SystemExit
# Keys AND values are allow-listed: a branch remote or an unknown extension can
# hold a credential-bearing URL, so neither is copied.
pattern=r'^(core\.(repositoryformatversion|bare|filemode|logallrefupdates|ignorecase|precomposeunicode|symlinks)|extensions\.(worktreeconfig|objectformat|refstorage))$'
p=subprocess.run(['git','config','-f',src,'--null','--get-regexp',pattern],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
if p.returncode not in (0,1): raise SystemExit(1)
for record in p.stdout.split(b'\0'):
 if not record: continue
 try: key,value=record.decode('utf-8','surrogateescape').split('\n',1)
 except ValueError: raise SystemExit(1)
 if not re.fullmatch(r'[A-Za-z0-9_.-]{1,64}',value): continue
 subprocess.run(['git','config','-f',dst,'--add',key,value],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
PY
}
GIT_DIR="$(git -C "$CWD" rev-parse --absolute-git-dir 2>/dev/null || true)"

# A tmpfs root lets us create /workspace before any readonly host mount. Only
# the runtime system directories needed by the CLI are exposed below.
ARGS=(--tmpfs / --dir /workspace --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib64 /lib64)
# Never expose /run: it contains per-user IPC sockets which escape the sandbox.
# /etc remains readonly for ordinary runtime configuration. Its resolver is
# commonly an absolute symlink into /run, so expose only that resolved file at
# both the target path and /etc/resolv.conf, never the containing directory.
for p in /usr /etc /opt; do [ -e "$p" ] && ARGS+=(--ro-bind "$p" "$p"); done
# System git config can carry credentials (http.extraHeader, URLs): blank it, and
# GIT_CONFIG_NOSYSTEM below stops git reading any build-specific system path.
[ -f /etc/gitconfig ] && ARGS+=(--ro-bind /dev/null /etc/gitconfig)
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
if [ "$ACCESS" = edit ]; then ARGS+=(--bind "$COPYDIR" /workspace); else ARGS+=(--ro-bind "$CWD" /workspace); fi
if [ -n "$GIT_COMMON_DIR" ]; then ensure_box_parents "$GIT_COMMON_DIR"; ARGS+=(--ro-bind "$GIT_COMMON_DIR" "$GIT_COMMON_DIR"); fi
if [ "$ACCESS" = edit ]; then ARGS+=(--ro-bind "$CWD/.git" /workspace/.git); fi
add_git_overlays() {
  local hostdir="$1" boxdir="$2" label="$3" cfg empty
  [ -d "$hostdir" ] || return
  if [ -f "$hostdir/config" ]; then
    cfg="$SANITIZED_GIT_DIR/$label-config"; sanitize_git_config "$hostdir/config" "$cfg" || fail could_not_sanitize_git_config
    ARGS+=(--ro-bind "$cfg" "$boxdir/config")
  fi
  if [ -f "$hostdir/config.worktree" ]; then
    cfg="$SANITIZED_GIT_DIR/$label-config.worktree"; sanitize_git_config "$hostdir/config.worktree" "$cfg" || fail could_not_sanitize_git_config
    ARGS+=(--ro-bind "$cfg" "$boxdir/config.worktree")
  fi
  if [ -e "$hostdir/FETCH_HEAD" ]; then
    empty="$SANITIZED_GIT_DIR/$label-FETCH_HEAD"; : > "$empty"
    ARGS+=(--ro-bind "$empty" "$boxdir/FETCH_HEAD")
  fi
}
if [ -n "$GIT_COMMON_DIR" ]; then add_git_overlays "$GIT_COMMON_DIR" "$GIT_COMMON_DIR" common; fi
# Only overlay git dirs that are actually mounted: CWD/.git itself, or a linked
# worktree's gitdir inside the validated common dir. Anything else is not visible.
if [ -n "$GIT_DIR" ] && [ -d "$GIT_DIR" ]; then
  if [ "$GIT_DIR" = "$CWD/.git" ]; then add_git_overlays "$GIT_DIR" /workspace/.git worktree
  elif [ -n "$GIT_COMMON_DIR" ] && [ "${GIT_DIR#"$GIT_COMMON_DIR"/worktrees/}" != "$GIT_DIR" ]; then add_git_overlays "$GIT_DIR" "$GIT_DIR" worktree; fi
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

# ~/.gemini also holds a browser profile, other tools' chat history and account
# lists, so none of it is exposed. The box sees one fresh, empty, throwaway
# antigravity-cli tree (memory, history and agy's bin/agentapi shim all start
# empty and die with the run) plus readonly copies of only what the CLI needs to
# start: its settings, OAuth token (a documented exception), install id and
# built-ins. Nothing written there reaches the host.
GEMINI="$HOME/.gemini"; AGY_STATE="$GEMINI/antigravity-cli"
PRIVATE_STATE="$PRIVTMP/agy-state"; mkdir -p "$PRIVATE_STATE" || fail could_not_create_private_state
ensure_box_parents "$AGY_STATE"; ARGS+=(--dir "$GEMINI" --bind "$PRIVATE_STATE" "$AGY_STATE")
for p in settings.json antigravity-oauth-token installation_id builtin; do
  if [ -f "$AGY_STATE/$p" ] && [ ! -L "$AGY_STATE/$p" ]; then : > "$PRIVATE_STATE/$p"; ARGS+=(--ro-bind "$AGY_STATE/$p" "$AGY_STATE/$p")
  elif [ -d "$AGY_STATE/$p" ] && [ ! -L "$AGY_STATE/$p" ]; then mkdir -p "$PRIVATE_STATE/$p"; ARGS+=(--ro-bind "$AGY_STATE/$p" "$AGY_STATE/$p"); fi
done
ARGS+=(--ro-bind "$BINARY" /agy)
ensure_box_parents "$BINARY"; ARGS+=(--ro-bind "$BINARY" "$BINARY")
# /relay contains task input only. Worker stdout is captured through the
# supervisor's already-open host FD, so a worker cannot replace answer.md with
# a symlink that the host later reopens by name.
ARGS+=(--dir /relay --ro-bind "$TASK_COPY" /relay/task.md)
ARGS+=(--unshare-ipc --unshare-pid --new-session --unshare-uts --clearenv)
ARGS+=(--setenv GIT_CONFIG_NOSYSTEM 1 --setenv HOME "$HOME" --setenv PATH "${PATH:-/usr/bin:/bin}" --setenv LANG "${LANG:-C.UTF-8}" --setenv TERM "${TERM:-dumb}" --setenv TZ "${TZ:-UTC}")
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
EDIT_RESULT='{}'
if [ "$ACCESS" = edit ]; then
  # Test-only: exercise the defence against a disappeared private copy. This
  # variable is intentionally not forwarded through bwrap's --clearenv.
  if [ "${MODEL_POLICY_AGY_TEST_DROP_COPY:-}" = 1 ]; then rm -rf -- "$COPYDIR"; fi
  # Let copy-back own signals: it journals and rolls them back. The shell must
  # neither exit early nor remove its source copy while that is happening.
  trap '' INT TERM HUP
  EDIT_RESULT="$(python3 - "$CWD" "$COPYDIR" "$BASELINE" 2>>"$OUTDIR/copyback.err" <<'PY'
import hashlib,json,os,re,signal,stat,sys,tempfile
cwd,copy,baseline_path=sys.argv[1:]
def copy_missing(path):
 print(json.dumps({'ok':False,'reason':'edit_rejected:copy_missing:'+path,'rejected':{'rule':'copy_missing','path':path}})); raise SystemExit
if not os.path.isdir(copy) or not os.path.lexists(os.path.join(copy,'.git')): copy_missing('copydir')
try: base=json.load(open(baseline_path,encoding='utf-8'))
except Exception: copy_missing('baseline')
valid_component=re.compile(r'^[A-Za-z0-9_][A-Za-z0-9._+-]*$')
deny={'claude.md','claude.local.md','agents.md','agent.md','gemini.md','node_modules','jenkinsfile','azure-pipelines.yml','azure-pipelines.yaml','appveyor.yml','appveyor.yaml','cloudbuild.yml','cloudbuild.yaml','bitbucket-pipelines.yml','buildspec.yml','buildspec.yaml','codemagic.yaml','bitrise.yml','wercker.yml'}
def sha(path):
 h=hashlib.sha256()
 with open(path,'rb') as f:
  for b in iter(lambda:f.read(65536),b''): h.update(b)
 return h.hexdigest()
def reject(rule,path): print(json.dumps({'ok':False,'reason':'edit_rejected:'+rule+':'+path,'rejected':{'rule':rule,'path':path}})); raise SystemExit
def conflict(path): print(json.dumps({'ok':False,'reason':'edit_conflict','rejected':{'rule':'edit_conflict','path':path}})); raise SystemExit
def path_ok(rel):
 parts=rel.split('/')
 return bool(rel) and len(rel)<=1024 and all(valid_component.match(x) and x.lower() not in deny for x in parts)
current={}; dirs=[]
for root,ds,fs in os.walk(copy,followlinks=False):
 relroot=os.path.relpath(root,copy)
 # .git is a bwrap mountpoint, never part of the worker's change set.
 if relroot=='.git': ds[:]=[]; continue
 for n in list(ds)+list(fs):
  p=os.path.join(root,n); rel=os.path.relpath(p,copy)
  if rel=='.git' or rel.startswith('.git/'): continue
  st=os.lstat(p)
  if stat.S_ISDIR(st.st_mode): dirs.append(rel); continue
  current[rel]={'mode':stat.S_IMODE(st.st_mode),'regular':stat.S_ISREG(st.st_mode),'nlink':st.st_nlink,'size':st.st_size,'sha256':sha(p) if stat.S_ISREG(st.st_mode) else None}
base_dirs=set()
for p in base:
 parts=p.split('/')[:-1]
 for i in range(1,len(parts)+1): base_dirs.add('/'.join(parts[:i]))
# A baseline file replaced with a directory would otherwise look like a safe
# deletion plus children. It is a non-regular replacement and rejects whole
# delta before any host write.
for p in dirs:
 if p in base: reject('non_regular',p)
added=sorted(set(current)-set(base)); deleted=sorted(set(base)-set(current)); modified=sorted(p for p in set(current)&set(base) if not current[p]['regular'] or current[p]['sha256']!=base[p]['sha256'] or bool(current[p]['mode']&0o111)!=bool(base[p]['mode']&0o111))
changed=added+modified+deleted
for p in changed:
 if not path_ok(p): reject('path',p)
# Git treats any directory holding HEAD + objects/ + refs/ as a bare repository
# and obeys its config (core.fsmonitor, hooks) when run inside it, whatever the
# name. Reject a delta that names or completes such a directory.
# Deletions count too, checked in the host tree as well: deleting HEAD would
# otherwise hide the very marker the copy-side check looks for.
for p in changed:
 if any(x.lower().endswith('.git') for x in p.split('/')[:-1]): reject('git_repo',p)
 # Paths inside an existing nested repo (its own .git, file or dir) are off limits.
 parts=p.split('/')[:-1]
 if any(os.path.lexists(os.path.join(cwd,*parts[:i],'.git')) for i in range(1,len(parts)+1)): reject('git_repo',p)
 for top in (copy,cwd):
  d=os.path.join(top,os.path.dirname(p))
  while os.path.isdir(d):
   if os.path.isfile(os.path.join(d,'HEAD')) and os.path.isdir(os.path.join(d,'objects')) and os.path.isdir(os.path.join(d,'refs')): reject('git_repo',p)
   if os.path.samefile(d,top): break
   d=os.path.dirname(d)
for p in added+modified:
 x=current[p]
 if not x['regular'] or x['nlink'] != 1: reject('non_regular',p)
 if x['size'] > 5*1024*1024: reject('file_too_large',p)
 if p in base and bool(x['mode']&0o111) != bool(base[p]['mode']&0o111): reject('mode_change',p)
for p in deleted:
 if p not in base: reject('delete_invalid',p)
if len(changed)>500: reject('too_many_paths',changed[500])
if sum(current[p]['size'] for p in added+modified) > 20*1024*1024: reject('too_many_bytes',(added+modified)[0] if added+modified else '')
# Empty new directories are not copied back. A non-empty directory can only be a
# parent of an accepted file; reject node_modules even when it is otherwise empty.
for d in dirs:
 if d not in base_dirs:
  if any(x.lower() in deny for x in d.split('/')): reject('path',d)
  if not any(p.startswith(d+'/') for p in added+modified): continue
# Check every host precondition before a single write.
host_modes={}
for p in added:
 if os.path.lexists(os.path.join(cwd,p)): conflict(p)
for p in modified+deleted:
 hp=os.path.join(cwd,p)
 try: st=os.lstat(hp)
 except FileNotFoundError: conflict(p)
 if not stat.S_ISREG(st.st_mode) or sha(hp)!=base[p]['host_sha256']: conflict(p)
 host_modes[p]=stat.S_IMODE(st.st_mode)
created_dirs=[]
def parent(rel):
 st=os.lstat(cwd)
 if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode): raise RuntimeError('unsafe parent')
 d=cwd
 for part in rel.split('/')[:-1]:
  d=os.path.join(d,part)
  try: st=os.lstat(d)
  except FileNotFoundError:
   os.mkdir(d,0o755); created_dirs.append(d); st=os.lstat(d)
  if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode): raise RuntimeError('unsafe parent')
 return d
def relpath(path): return os.path.relpath(path,cwd)
def temp_name(d,prefix):
 # O_EXCL and O_NOFOLLOW make these names private transaction files.
 for _ in range(100):
  p=os.path.join(d,prefix+next(tempfile._get_candidate_names()))
  if not os.path.lexists(p): return p
 raise RuntimeError('could not allocate transaction name')
def clean_staging(stages):
 failed=[]
 for p in stages:
  if os.path.lexists(p):
   try: os.unlink(p)
   except Exception: failed.append(relpath(p))
 for d in reversed(created_dirs):
  try: os.rmdir(d)
  except FileNotFoundError: pass
  except Exception: failed.append(relpath(d))
 return failed
class ApplyFailure(Exception):
 def __init__(self,path): self.path=path
class ApplySignal(ApplyFailure): pass
def checked_host(p):
 hp=os.path.join(cwd,p); st=os.lstat(hp)
 if not stat.S_ISREG(st.st_mode) or sha(hp)!=base[p]['host_sha256']: raise ApplyFailure(p)
 return hp
# Test hooks: relay-only MODEL_POLICY_AGY_FAIL_* only inject failures; --clearenv keeps them out of the box.
fail_at=int(os.environ.get('MODEL_POLICY_AGY_FAIL_AT','0') or 0)
fail_rollback=os.environ.get('MODEL_POLICY_AGY_FAIL_ROLLBACK')=='1'
fail_bak_unlink=os.environ.get('MODEL_POLICY_AGY_FAIL_BAK_UNLINK')=='1'
rename_count=0; rollback_fault_used=False
def commit_rename(src,dst,p):
 global rename_count
 rename_count+=1
 if fail_at==rename_count: raise ApplyFailure(p)
 os.rename(src,dst)
def signal_abort(signum,frame): raise ApplySignal('')
old_handlers={}
stages=[]; journal=[]; failed_path=''
try:
 for sig in (signal.SIGTERM,signal.SIGINT,signal.SIGHUP):
  old_handlers[sig]=signal.getsignal(sig); signal.signal(sig,signal_abort)
 # Resolve (and, where needed, create) every parent before touching a host file,
 # so an unsafe parent cannot yield a partially applied change set.
 for p in added+modified:
  try: parent(p)
  except Exception: raise ApplyFailure(p)
 # Stage every new payload before moving any target into the journal.
 for p in added+modified:
  try:
   d=parent(p); stage=temp_name(d,'.agy-stage-')
   fd=os.open(stage,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
   stages.append(stage)
   try:
    with os.fdopen(fd,'wb') as o, open(os.path.join(copy,p),'rb') as i:
     for b in iter(lambda:i.read(65536),b''): o.write(b)
     o.flush(); os.fsync(o.fileno())
   except Exception:
    try: os.close(fd)
    except Exception: pass
    raise
   os.chmod(stage,0o644 if p in added else host_modes[p])
  except ApplyFailure: raise
  except Exception: raise ApplyFailure(p)
 stage_by_path=dict(zip(added+modified,stages))
 # Commit only renames. Each entry records the durable steps needed to undo it.
 for p in modified:
  target=checked_host(p); stage=stage_by_path[p]; backup=temp_name(os.path.dirname(target),'.agy-bak-')
  item={'path':p,'kind':'modified','target':target,'stage':stage,'backup':backup,'backup_moved':False,'applied':False,'steps':[]}; journal.append(item)
  if os.path.lexists(backup): raise ApplyFailure(p)
  commit_rename(target,backup,p); item['backup_moved']=True; item['steps'].append('backup')
  commit_rename(stage,target,p); item['applied']=True; item['steps'].append('replace')
 for p in added:
  target=os.path.join(cwd,p); stage=stage_by_path[p]
  if os.path.lexists(target): raise ApplyFailure(p)
  item={'path':p,'kind':'added','target':target,'stage':stage,'backup':None,'backup_moved':False,'applied':False,'steps':[]}; journal.append(item)
  commit_rename(stage,target,p); item['applied']=True; item['steps'].append('add')
 for p in deleted:
  target=checked_host(p); backup=temp_name(os.path.dirname(target),'.agy-bak-')
  item={'path':p,'kind':'deleted','target':target,'stage':None,'backup':backup,'backup_moved':False,'applied':False,'steps':[]}; journal.append(item)
  if os.path.lexists(backup): raise ApplyFailure(p)
  commit_rename(target,backup,p); item['backup_moved']=True; item['applied']=True; item['steps'].append('delete')
except ApplyFailure as e:
 failed_path=e.path
except Exception:
 failed_path=failed_path or ''
else:
 # The transaction is durable; later backup cleanup cannot make it partial.
 for sig,handler in old_handlers.items(): signal.signal(sig,handler)
 # Once every rename is committed, backups are merely recoverable leftovers.
 leftovers=[]
 for item in journal:
  if item['backup_moved'] and os.path.lexists(item['backup']):
   if fail_bak_unlink:
    leftovers.append(relpath(item['backup'])); continue
   try:
    os.unlink(item['backup'])
   except Exception: leftovers.append(relpath(item['backup']))
 changes={'added':added,'modified':modified,'deleted':deleted}
 if leftovers: print(json.dumps({'ok':False,'reason':'edit_partial','changes':changes,'partial':{'applied':changed,'restored':[],'unknown':[],'leftovers':leftovers}})); raise SystemExit
 print(json.dumps({'ok':True,'changes':changes})); raise SystemExit
# An interrupted or failed commit rolls its journal backwards. Continue after a
# rollback error so unrelated paths are restored whenever that is still possible.
rollback_errors=[]
for item in reversed(journal):
 try:
  # A signal can land between a rename and its journal flag, so decide from
  # what is on disk: a backup that exists is always put back.
  if not os.path.lexists(item['backup'] or '') and not (item['kind']=='added' and os.path.lexists(item['target']) and not os.path.lexists(item['stage'])): continue
  if fail_rollback and not rollback_fault_used:
   rollback_fault_used=True; raise RuntimeError('injected rollback failure')
  if item['kind']=='added':
   if os.path.lexists(item['target']) and not os.path.lexists(item['stage']): os.unlink(item['target'])
  elif os.path.lexists(item['backup']):
   os.rename(item['backup'],item['target'])
 except Exception:
  rollback_errors.append(item['path'])
stage_leftovers=clean_staging(stages)
for sig,handler in old_handlers.items(): signal.signal(sig,handler)
def state(p):
 hp=os.path.join(cwd,p)
 try: st=os.lstat(hp)
 except FileNotFoundError: st=None
 if p in added:
  if st is None: return 'restored'
  if stat.S_ISREG(st.st_mode) and sha(hp)==current[p]['sha256']: return 'applied'
 elif p in modified:
  if st and stat.S_ISREG(st.st_mode):
   h=sha(hp)
   if h==base[p]['host_sha256']: return 'restored'
   if h==current[p]['sha256']: return 'applied'
 elif p in deleted:
  if st is None: return 'applied'
  if stat.S_ISREG(st.st_mode) and sha(hp)==base[p]['host_sha256']: return 'restored'
 return 'unknown'
leftovers=stage_leftovers[:]
for item in journal:
 if item['backup'] and os.path.lexists(item['backup']): leftovers.append(relpath(item['backup']))
states={p:state(p) for p in changed}
if rollback_errors or leftovers or any(v!='restored' for v in states.values()):
 print(json.dumps({'ok':False,'reason':'edit_partial','partial':{'applied':[p for p in changed if states[p]=='applied'],'restored':[p for p in changed if states[p]=='restored'],'unknown':[p for p in changed if states[p]=='unknown'],'leftovers':leftovers}})); raise SystemExit
print(json.dumps({'ok':False,'reason':'edit_rejected:apply_failed:'+failed_path,'rejected':{'rule':'apply_failed','path':failed_path}}))
PY
)"
  trap interrupt_worker INT TERM HUP
fi
python3 - "$SUP" "$POOL" "$MODEL" "$ACCESS" "$CWD" "$OUT" "$ERR" "$FORCED_REASON" "$EDIT_RESULT" <<'PY'
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
pool,model,access,cwd,out,err,forced,edit=sys.argv[2:]
# The supervisor already marks an empty answer as failed; name the real cause when
# agy says a headless permission prompt was auto-denied.
try:
 stderr_bytes,_=safe_read(err); stderr=stderr_bytes.decode('utf-8','replace')
 answer_bytes,answer_size=safe_read(out)
 if answer_size==0 and any(x.startswith('jetski: no output produced') for x in stderr.splitlines()):
  m=re.search(r'"([a-z_]+)" permission',stderr)
  result['ok']=False; result['reason']='agy_permission_denied:'+(m.group(1) if m else 'unknown')
except Exception: pass
result.update({'pool':pool,'model':model,'access':access,'cwd':cwd}); result.pop('effort',None); result.pop('sandbox',None)
if forced:
 result.update({'ok':False,'reason':forced})
if access=='edit':
 try:
  e=json.loads(edit)
  if e.get('changes') is not None: result['changes']=e['changes']
  if e.get('partial') is not None: result['partial']=e['partial']
  if e.get('leftovers') is not None: result['leftovers']=e['leftovers']
  if not e.get('ok',False):
   result.update({'ok':False,'reason':e.get('reason','edit_rejected:unknown:')})
   if e.get('rejected') is not None: result['rejected']=e['rejected']
 except Exception:
  # No result from copy-back (it crashed or was killed): the host state is not
  # known, so never claim the change set was rejected.
  result.update({'ok':False,'reason':'edit_state_unknown','check':'git -C %s status --short' % cwd})
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
