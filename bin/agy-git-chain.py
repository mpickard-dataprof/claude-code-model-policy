#!/usr/bin/env python3
"""Validate only the git metadata chain a linked worktree needs exposed."""
import json, os, stat, sys

cwd = os.path.realpath(sys.argv[1])
git = os.path.join(cwd, '.git')
out = {'valid': False, 'common': ''}
try:
    st = os.lstat(git)
    if stat.S_ISDIR(st.st_mode):
        # A normal checkout keeps all git metadata below the workspace itself.
        out = {'valid': True, 'common': ''}
    elif stat.S_ISREG(st.st_mode):
        data = open(git, 'r', encoding='utf-8').read()
        lines = data.splitlines()
        if len(lines) != 1 or not lines[0].startswith('gitdir: '): raise ValueError()
        raw = lines[0][8:]
        if not raw or '\x00' in raw: raise ValueError()
        gd = os.path.realpath(raw if os.path.isabs(raw) else os.path.join(cwd, raw))
        if os.path.basename(os.path.dirname(gd)) != 'worktrees' or not os.path.isdir(gd): raise ValueError()
        common = os.path.realpath(os.path.dirname(os.path.dirname(gd)))
        commondir = os.path.join(gd, 'commondir')
        if os.path.lexists(commondir):
            if not stat.S_ISREG(os.lstat(commondir).st_mode): raise ValueError()
            c = open(commondir, 'r', encoding='utf-8').read().strip()
            if os.path.realpath(c if os.path.isabs(c) else os.path.join(gd, c)) != common: raise ValueError()
        back_path = os.path.join(gd, 'gitdir')
        if not stat.S_ISREG(os.lstat(back_path).st_mode): raise ValueError()
        back = open(back_path, 'r', encoding='utf-8').read().strip()
        if os.path.realpath(back if os.path.isabs(back) else os.path.join(gd, back)) != os.path.realpath(git): raise ValueError()
        if not os.path.isdir(common): raise ValueError()
        if os.path.basename(common) != '.git' and not all(os.path.exists(os.path.join(common, x)) for x in ('HEAD', 'objects', 'refs')): raise ValueError()
        out = {'valid': True, 'common': common}
except Exception:
    pass
print(json.dumps(out))
