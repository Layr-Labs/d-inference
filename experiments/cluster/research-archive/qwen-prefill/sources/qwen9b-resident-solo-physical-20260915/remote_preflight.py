from pathlib import Path
import fcntl,hashlib,json,os,stat,subprocess,sys
root=Path(value['remoteRoot'])
assert root==Path('/Users/developer/DarkbloomDev/qwen9b-resident-solo-generation-20260915') and root.resolve()==root
sys.path.insert(0,str(root/'supervisor'));from reference_resources import sample_local,validate_local
observed={}
for item in value['files']:
 p=root/item['path'];fd=os.open(p,os.O_RDONLY|os.O_NOFOLLOW);s=os.fstat(fd)
 assert stat.S_ISREG(s.st_mode) and s.st_size==item['bytes'] and s.st_uid==os.getuid() and s.st_nlink==1 and stat.S_IMODE(s.st_mode)==int(item['mode'],8)
 h=hashlib.sha256()
 with os.fdopen(fd,'rb') as f:
  for chunk in iter(lambda:f.read(1048576),b''):h.update(chunk)
 assert h.hexdigest()==item['sha256'];observed[item['path']]=dict(bytes=s.st_size,sha256=h.hexdigest(),mode=stat.S_IMODE(s.st_mode))
for item in value['directories']:
 p=root/item['path'];s=p.lstat();assert stat.S_ISDIR(s.st_mode) and stat.S_IMODE(s.st_mode)==int(item['mode'],8) and s.st_uid==os.getuid()
assert not list((root/'runs').iterdir())
ps=subprocess.check_output(['/bin/ps','-axo','pid=,comm='],text=True);active=[]
for line in ps.splitlines():
 parts=line.strip().split(maxsplit=1)
 if len(parts)==2:
  name=Path(parts[1]).name.lower()
  if name.startswith(('darkbloom','qwen')) or name in {'cluster-inference','owner-controller'}:active.append(line.strip())
assert not active,active
j=Path('/Users/developer/.darkbloom/cluster-device/native-device.lease');fd=os.open(j,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
try:
 fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);s=os.fstat(fd);n=j.lstat()
 assert stat.S_ISREG(s.st_mode) and stat.S_IMODE(s.st_mode)==0o600 and s.st_uid==os.getuid() and s.st_nlink==1 and s.st_size==0 and (s.st_dev,s.st_ino)==(n.st_dev,n.st_ino)
 identity=dict(device=s.st_dev,inode=s.st_ino,bytes=s.st_size)
finally:os.close(fd)
r=sample_local();validate_local(r);print(json.dumps(dict(verified=observed,active=active,journal=identity,evidenceEmpty=True,resource=r)))
