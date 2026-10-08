from pathlib import Path
import base64, json, os, select, shlex, subprocess, time
from guards import SSH, REMOTE

def line_until(stream, seconds):
    end=time.monotonic()+seconds; value=bytearray()
    while b'\n' not in value:
        if time.monotonic()>=end: raise RuntimeError('Bounded control output deadline exceeded')
        if not select.select([stream],[],[],0.2)[0]: continue
        block=os.read(stream.fileno(),1)
        if not block or len(value)>65536: raise RuntimeError('Control stream ended or exceeded bound')
        value.extend(block)
    return json.loads(value)

def fetch_token(destination):
    code="from pathlib import Path; p=Path('/Users/developer/.darkbloom/local_token'); assert p.is_file() and not p.is_symlink() and p.stat().st_size<=4096; print(p.read_text().strip())"
    result=subprocess.run(SSH+['darkbloom-24',shlex.join(['/usr/bin/python3','-c',code])],capture_output=True,timeout=10)
    if result.returncode: return False
    raw=result.stdout.strip()
    if not 16<=len(raw)<=4096 or any(c<33 or c>126 for c in raw): raise RuntimeError('Invalid private token file')
    with os.fdopen(os.open(destination,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600),'wb') as file: file.write(raw)
    return True

def postflight(host, remote_run=None):
    code=r'''
from pathlib import Path
import base64,hashlib,json,subprocess,sys
ps=subprocess.check_output(['/bin/ps','-axo','pid=,comm='],text=True)
active=[line.strip() for line in ps.splitlines() if len(line.split(maxsplit=1))==2 and Path(line.split(maxsplit=1)[1]).name in ['darkbloom','darkbloom-cluster-worker','darkbloom-owner-qualification']]
p=Path('/Users/developer/.darkbloom/cluster-device/native-device.lease')
assert p.is_file() and not p.is_symlink() and p.stat().st_size<=65536
raw=p.read_bytes(); result={'active':active,'journalBytes':len(raw),'journalSHA256':hashlib.sha256(raw).hexdigest(),'files':{}}
if len(sys.argv)>1:
 root=Path(sys.argv[1])
 for name in ['provider.stdout','provider.stderr','supervisor.json']:
  p=root/name
  if p.exists():
   assert p.is_file() and not p.is_symlink() and p.stat().st_size<=1048576
   result['files'][name]=base64.b64encode(p.read_bytes()).decode()
print(json.dumps(result))
'''
    command=['/usr/bin/python3','-c',code]+([remote_run] if remote_run else [])
    result=subprocess.run(SSH+[host,shlex.join(command)],capture_output=True,text=True,timeout=15)
    if result.returncode: raise RuntimeError('Postflight failed on '+host+': '+result.stderr)
    return json.loads(result.stdout)

def discovery():
    code="from pathlib import Path; import json; p=Path('/Users/developer/.darkbloom/local.json'); assert p.is_file() and not p.is_symlink() and p.stat().st_size<=65536; x=json.loads(p.read_text()); print(json.dumps({k:x[k] for k in ['pid','host','port','base_url','version']}))"
    result=subprocess.run(SSH+['darkbloom-24',shlex.join(['/usr/bin/python3','-c',code])],capture_output=True,text=True,timeout=10)
    if result.returncode: raise RuntimeError('Cannot read owned listener discovery')
    return json.loads(result.stdout)
