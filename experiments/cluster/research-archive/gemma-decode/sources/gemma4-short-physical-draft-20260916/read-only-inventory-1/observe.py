from pathlib import Path
import os,json,hashlib,stat,subprocess
root=Path('/Users/developer/DarkbloomDev/models'); result={'models':[]}
for path in sorted(root.iterdir()):
 if 'gemma' not in path.name.lower():continue
 item={'path':str(path),'canonical':path.resolve()==path,'files':[],'metadata':{}}
 for f in sorted(path.iterdir()):
  s=f.lstat(); item['files'].append({'name':f.name,'bytes':s.st_size,'regular':stat.S_ISREG(s.st_mode),'uid':s.st_uid,'mode':s.st_mode,'inode':s.st_ino,'device':s.st_dev,'nlink':s.st_nlink})
  if f.name in ('manifest.json','config.json','model.safetensors.index.json'):
   assert stat.S_ISREG(s.st_mode) and s.st_size<=2*1024**2
   raw=f.read_bytes(); item['metadata'][f.name]={'sha256':hashlib.sha256(raw).hexdigest(),'bytes':len(raw)}
 result['models'].append(item)
for label,argv in [('en1',['/sbin/ifconfig','en1']),('rdma',['/usr/bin/ibv_devinfo','-d','rdma_en1']),('physicalMemory',['/usr/sbin/sysctl','-n','hw.memsize'])]:
 p=subprocess.run(argv,capture_output=True,timeout=3); assert len(p.stdout)+len(p.stderr)<65536
 result[label]={'exitCode':p.returncode,'stdout':p.stdout.decode(),'stderr':p.stderr.decode()}
print(json.dumps(result,sort_keys=True))
