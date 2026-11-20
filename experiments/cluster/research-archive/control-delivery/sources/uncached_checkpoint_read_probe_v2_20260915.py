import fcntl,hashlib,json,os,re,subprocess,time
from pathlib import Path

def observe():
 raw=subprocess.run(['/usr/bin/vm_stat'],capture_output=True,text=True,check=True,timeout=3).stdout
 page=int(re.search(r'page size of (\d+) bytes',raw).group(1)); vals={k:int(re.search(re.escape(k)+r':\s*(\d+)',raw).group(1))*page for k in ['Pages free','Anonymous pages','File-backed pages']}
 return dict(monotonic=time.monotonic(),values=vals,rawVMStat=raw)
files=list(Path('/Users/developer/DarkbloomDev/models/Qwen3.5-9B').glob('*.safetensors'));p=max(files,key=lambda x:x.stat().st_size)
length=min(1024**3,p.stat().st_size//2);results=[]
for passno in [0,1]:
 fd=os.open(p,os.O_RDONLY);count=0;h=hashlib.sha256();samples=[observe()];start=time.monotonic()
 try:
  assert fcntl.fcntl(fd,fcntl.F_NOCACHE,1)==0
  if passno==1:assert fcntl.fcntl(fd,45,0)==0
  while count<length:
   data=os.pread(fd,min(8*1024**2,length-count),passno*length+count)
   assert data;h.update(data);count+=len(data)
   if count%(64*1024**2)==0:
    samples.append(observe());assert samples[-1]['values']['Pages free']>=6*1024**3
   assert time.monotonic()-start<30
 finally:os.close(fd)
 del data
 samples.append(observe());results.append(dict(readAhead='default' if passno==0 else 'disabled',noCache=True,offset=passno*length,bytes=count,seconds=time.monotonic()-start,sha256=h.hexdigest(),samples=samples));print(json.dumps(results[-1]),flush=True)
print(json.dumps(dict(kind='cpu_only_uncached_checkpoint_read',file=p.name,modelInference=False,results=results)))
