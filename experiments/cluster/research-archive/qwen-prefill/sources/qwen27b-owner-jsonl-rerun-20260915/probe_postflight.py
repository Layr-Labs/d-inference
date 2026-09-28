"""Exact current HTTP postflight helper; no signals or journal mutation."""
from pathlib import Path
import base64, json, shlex, subprocess
from parent_settings import SSH

def postflight(host, remote_run=None, timeout=15):
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
    if not 0 < timeout <= 15: raise ValueError('Invalid postflight timeout')
    result=subprocess.run(SSH+[host,shlex.join(command)],capture_output=True,text=True,timeout=timeout)
    if result.returncode: raise RuntimeError('Postflight failed on '+host+': '+result.stderr)
    return json.loads(result.stdout)
