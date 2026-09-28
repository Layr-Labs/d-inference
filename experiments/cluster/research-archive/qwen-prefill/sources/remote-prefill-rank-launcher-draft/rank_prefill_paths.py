"""Pure path/argument admission and fixed remote bootstrap code."""
from pathlib import PurePosixPath
import re


def host_alias(value):
    if not isinstance(value, str) or re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}', value) is None:
        raise ValueError('Host must be an SSH alias without options, whitespace, or user syntax')
    return value


def absolute_path(value):
    # Restrict paths so observed ps arguments remain unambiguous as well as
    # quoting every SSH command through the existing shlex.join helper.
    if not isinstance(value, str) or re.fullmatch(r'/(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+', value) is None:
        raise ValueError('Remote path must be an absolute path with simple components')
    path = PurePosixPath(value)
    if '..' in path.parts or '.' in path.parts or str(path) != value:
        raise ValueError('Noncanonical remote path')
    return path


def paths(home, requested_root, model, run_id):
    if re.fullmatch('[0-9a-f]{32}', run_id) is None:
        raise ValueError('Invalid run UUID')
    home = absolute_path(home)
    root = absolute_path(requested_root) if requested_root else home / 'DarkbloomDev/cluster-runs'
    model = absolute_path(model)
    if root == model or root.is_relative_to(model) or model.is_relative_to(root):
        raise ValueError('Remote run root and model must be separate')
    run = root / run_id
    return dict(root=str(root), run=str(run), rank_directories=[str(run / ('rank-' + str(i))) for i in range(2)],
                controls=str(run / 'controls'), bundle=str(run / 'bundle'), model=str(model))


BOOTSTRAP = """import json,pathlib,socket,sys
root=pathlib.Path(sys.argv[1]); run=root/sys.argv[2]
root.mkdir(parents=True,exist_ok=True,mode=0o700)
if root.resolve()!=root: raise ValueError('Run root may not contain symlinks')
run.mkdir(mode=0o700)
for i in range(2): (run/('rank-'+str(i))).mkdir(mode=0o700)
(run/'metadata').mkdir(mode=0o700)
sockets=[]
try:
 for _ in range(2):
  s=socket.socket(socket.AF_INET,socket.SOCK_STREAM); sockets.append(s); s.bind(('127.0.0.1',0))
 hostfile=[['127.0.0.1:'+str(s.getsockname()[1])] for s in sockets]
 if hostfile[0]==hostfile[1]: raise ValueError('Distinct loopback ports required')
finally:
 for s in sockets: s.close()
print(json.dumps(dict(run=str(run),hostfile=hostfile,reservationOpen=False,
 method='remote_AF_INET_loopback_two_simultaneous_bind_then_close',raceFailsWithoutFallback=True)))
"""

ABSENT = """import pathlib,sys
p=pathlib.Path(sys.argv[1])
if p.exists() or p.is_symlink(): raise ValueError('Refusing SCP overwrite')
"""

# The fixed bootstrap verifies the script and every imported helper before
# executing any staged Python. Neither the model nor the bundle is read here.
PINNED_RUNNER = """import hashlib,json,pathlib,runpy,sys
p=pathlib.Path(sys.argv[1]); raw=p.read_bytes()
if len(raw)>1048576 or hashlib.sha256(raw).hexdigest()!=sys.argv[2]: raise ValueError('Control manifest mismatch')
m=json.loads(raw); entries=m['files']
if not 1<=len(entries)<=8: raise ValueError('Control file count')
seen=set()
for e in entries:
 name=e['path']
 if pathlib.Path(name).name!=name or name in seen: raise ValueError('Invalid control path')
 seen.add(name); f=p.parent/name
 if f.is_symlink() or not 0<=e['size_bytes']<=8388608 or f.stat().st_size!=e['size_bytes']: raise ValueError('Control file bounds')
 if hashlib.sha256(f.read_bytes()).hexdigest()!=e['sha256']: raise ValueError('Control file mismatch')
if seen!={'rank_prefill_control.py','prefill_compute_memory.py','artifacts.py','control-config.json'}: raise ValueError('Control file set')
sys.path.insert(0,str(p.parent)); sys.argv=[str(p.parent/'rank_prefill_control.py'),sys.argv[3]]
runpy.run_path(sys.argv[0],run_name='__main__')
"""
