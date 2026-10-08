
from pathlib import Path
import base64,hashlib,json,os,stat,subprocess
root=Path('/Users/developer/DarkbloomDev/qwen-target-verification-check-20260915/runs/physical-1');assert root.resolve()==root
result={};total=0
for p in sorted(root.rglob('*')):
 assert not p.is_symlink()
 if p.is_dir():continue
 assert p.parent.resolve()==p.parent
 fd=os.open(p,os.O_RDONLY|os.O_NOFOLLOW)
 try:
  before=os.fstat(fd);assert stat.S_ISREG(before.st_mode) and before.st_uid==os.getuid() and before.st_nlink==1 and before.st_size<=1048576
  raw=os.read(fd,1048577);after=os.fstat(fd)
  assert len(raw)==before.st_size and (before.st_ino,before.st_size,before.st_mtime_ns)==(after.st_ino,after.st_size,after.st_mtime_ns)
 finally:os.close(fd)
 total+=len(raw);assert total<=8*1048576 and len(result)<32
 result[str(p.relative_to(root))]={'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest(),'base64':base64.b64encode(raw).decode()}
j=Path('/Users/developer/.darkbloom/cluster-device/native-device.lease');assert not j.is_symlink() and j.stat().st_size==0
ps=subprocess.check_output(['/bin/ps','-axo','pid=,comm='],text=True);active=[]
for line in ps.splitlines():
 fields=line.strip().split(maxsplit=1)
 if len(fields)==2:
  name=Path(fields[1]).name.lower()
  if name.startswith(('darkbloom','qwen')) or name in {'targetverificationcheck','cluster-inference','owner-controller'}:active.append(line.strip())
print(json.dumps({'files':result,'active':active,'journalBytes':j.stat().st_size}))
