"""Retain bounded remote reference evidence and a fresh process/journal observation."""
import base64
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys


REMOTE = r'''from pathlib import Path
import base64,hashlib,json,subprocess,sys
p=Path('/Users/developer/DarkbloomDev/qwen27b-resident-solo-short-generation-20260916/runs')/sys.argv[1]
items=[]
for f in sorted(p.rglob('*')):
 if f.is_file():
  assert not f.is_symlink()
  raw=f.read_bytes(); assert len(raw)<=16*1024*1024 and len(items)<16
  items.append(dict(path=str(f.relative_to(p)),bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest(),data=base64.b64encode(raw).decode()))
ps=subprocess.check_output(['/bin/ps','-axo','pid=,comm='],text=True)
active=[]
for line in ps.splitlines():
 parts=line.strip().split(maxsplit=1)
 if len(parts)==2:
  name=Path(parts[1]).name.lower()
  if name.startswith(('darkbloom','qwen')) or name in {'cluster-inference','owner-controller'}: active.append(line.strip())
j=Path('/Users/developer/.darkbloom/cluster-device/native-device.lease')
assert j.is_file() and not j.is_symlink()
print(json.dumps(dict(files=items,active=active,journalBytes=j.stat().st_size)))
'''


def main():
    assert len(sys.argv) == 2 and sys.argv[1].isdigit() and 1 <= int(sys.argv[1]) <= 32
    number = int(sys.argv[1])
    base = Path(__file__).resolve().parent / ('run-' + str(number))
    assert base.is_dir()
    returned = base / 'returned'
    returned.mkdir(mode=0o700)
    from parent_settings import SSH
    command = SSH + ['-S', 'none', 'darkbloom-48',
               shlex.join(['/usr/bin/python3', '-B', '-c', REMOTE, 'cohort-' + str(number)])]
    completed = subprocess.run(command, capture_output=True, timeout=30)
    (base / 'retrieval.stdout').write_bytes(completed.stdout)
    (base / 'retrieval.stderr').write_bytes(completed.stderr)
    assert completed.returncode == 0 and not completed.stderr
    packet = json.loads(completed.stdout)
    for item in packet['files']:
        part = Path(item['path'])
        assert not part.is_absolute() and '..' not in part.parts
        raw = base64.b64decode(item['data'], validate=True)
        assert len(raw) == item['bytes'] and hashlib.sha256(raw).hexdigest() == item['sha256']
        target = returned / part
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(raw)
    terminal = json.loads((returned / 'terminal.json').read_text())
    review = dict(status=terminal['status'], filesVerified=len(packet['files']),
                  active=packet['active'], journalBytes=packet['journalBytes'],
                  nativeStderr=(returned / 'native/worker-0.stderr').read_text(), terminal=terminal)
    (base / 'root-review.json').write_text(json.dumps(review, indent=2) + '\n')
    assert not packet['active'] and packet['journalBytes'] == 0
    print(json.dumps({key: review[key] for key in ('status', 'filesVerified', 'active', 'journalBytes', 'nativeStderr')}))


if __name__ == '__main__':
    main()
