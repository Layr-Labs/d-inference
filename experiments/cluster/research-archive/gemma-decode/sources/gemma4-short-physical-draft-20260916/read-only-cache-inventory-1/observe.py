from pathlib import Path
import json,os,stat,hashlib
p=Path('/Users/developer/.cache/huggingface/hub/models--gemma-4-26b-qat-4bit/snapshots/local')
r={'path':str(p),'exists':p.exists(),'files':[]}
if p.exists():
 r['canonical']=p.resolve()==p
 for f in sorted(p.iterdir()):
  s=f.lstat();v={'name':f.name,'bytes':s.st_size,'regular':stat.S_ISREG(s.st_mode),'symlink':stat.S_ISLNK(s.st_mode),'uid':s.st_uid,'mode':s.st_mode,'inode':s.st_ino,'device':s.st_dev,'nlink':s.st_nlink}
  if f.name in ('config.json','manifest.json','model.safetensors.index.json'):
   assert stat.S_ISREG(s.st_mode) and s.st_size<=2*1024**2
   v['sha256']=hashlib.sha256(f.read_bytes()).hexdigest()
  r['files'].append(v)
print(json.dumps(r,sort_keys=True))
