import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import time

root=Path(__file__).resolve().parent
package=root/'resident-cache-off-package-20260915'
destination='/Users/developer/DarkbloomDev/resident-cache-off-runtime-20260915'
manifest=json.loads((package/'manifest.json').read_bytes())
manifest_pin=hashlib.sha256((package/'manifest.json').read_bytes()).hexdigest()
checks=json.loads((root/'resident-cache-off-build-20260915/records/cpu-checks.json').read_bytes())
assert checks['nativeSHA256']==manifest['native_sha256'] and len(checks['checks'])==2
assert all(x['nativeExitCode']==0 and x['stderrBytes']==0 and x['priorRecordsByteIdentical'] for x in checks['checks'])
verify='''from pathlib import Path
import hashlib,json,sys
def digest(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
p=Path(sys.argv[1]);assert digest(p/'manifest.json')==sys.argv[2]
m=json.loads((p/'manifest.json').read_bytes())
for row in m['files']:
 f=p/row['path'];assert f.is_file() and not f.is_symlink()
 assert f.stat().st_size==row['size_bytes'] and digest(f)==row['sha256']
assert digest(p/'bundle/cluster-inference')==m['native_sha256']
print(json.dumps(dict(verifiedMembers=len(m['files']),nativeSHA256=m['native_sha256'],
 manifestSHA256=sys.argv[2],sourceSnapshotSHA256=m['source_snapshot_sha256'],destination=str(p))))
'''
results=[]
for host in ['darkbloom-24','darkbloom-48']:
    start=time.monotonic()
    preflight=['/usr/bin/python3','-c','import os,sys; assert not os.path.lexists(sys.argv[1])',destination]
    subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=8',host,shlex.join(preflight)],check=True,timeout=15)
    subprocess.run(['scp','-q','-r',str(package),host+':'+destination],check=True,timeout=90)
    result=subprocess.run(['ssh','-o','BatchMode=yes',host,shlex.join(['/usr/bin/python3','-',destination,manifest_pin])],
                          input=verify,capture_output=True,text=True,check=True,timeout=45)
    assert not result.stderr
    item=json.loads(result.stdout);item.update(host=host,copyAndVerifySeconds=time.monotonic()-start)
    results.append(item)
    (root/'resident-cache-off-remote-verification-20260915.json').write_text(json.dumps(results,indent=2)+'\n')
    print(json.dumps(item),flush=True)
