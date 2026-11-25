from pathlib import Path
import os,sys,json,hashlib,stat,subprocess,fcntl
root=Path('/Users/developer/DarkbloomDev/installed-distributed-http-delivery-runtime-20260915'); value=json.loads(sys.stdin.buffer.read(65537));result=[]
for item in value['files']:
 p=root/item['path']; assert p.resolve()==p; s=p.stat();assert stat.S_ISREG(s.st_mode) and s.st_uid==os.getuid() and not s.st_mode&0o022 and s.st_size==item['bytes'];h=hashlib.sha256()
 with p.open('rb') as f:
  for block in iter(lambda:f.read(1048576),b''):h.update(block)
 assert h.hexdigest()==item['sha256'];result.append({'path':item['path'],'sha256':h.hexdigest()})
ps=subprocess.check_output(['/bin/ps','-axo','pid=,comm='],text=True,timeout=5);active=[line for line in ps.splitlines() if len(line.split(maxsplit=1))==2 and (Path(line.split(maxsplit=1)[1]).name.lower().startswith(('darkbloom','qwen')) or Path(line.split(maxsplit=1)[1]).name in ('cluster-inference','owner-controller'))];assert not active
journal=Path('/Users/developer/.darkbloom/cluster-device/native-device.lease');fd=os.open(journal,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
try:
 fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);s=os.fstat(fd);assert s.st_size==0 and s.st_uid==os.getuid() and s.st_nlink==1
finally:os.close(fd)
p=Path('/Users/developer/.config/darkbloom/provider.toml'); assert not p.is_symlink() and stat.S_IMODE(p.stat().st_mode)==0o600;assert hashlib.sha256(p.read_bytes()).hexdigest()==value['providerHash']
assert not (root/'qualification/balanced-attempt1').exists() and not (root/'configuration-transactions/balanced-http-1').exists()
sys.path.insert(0,str(root/'qualification-tools'));from reference_resources import sample_local,validate_local
resource=sample_local();validate_local(resource);print(json.dumps({'verified':result,'resource':resource,'active':active,'journalBytes':0,'defaultProviderHash':value['providerHash']}))
