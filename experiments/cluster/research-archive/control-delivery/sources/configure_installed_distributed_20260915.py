from pathlib import Path
import base64, hashlib, json, os, shlex, subprocess

ROOT=Path('/Users/developer/DarkbloomDev/cluster-research')
SOURCE=ROOT/'installed-product-qualification-plan-20260915'
OUT=ROOT/'installed-distributed-configuration-20260915'
REMOTE='/Users/developer/DarkbloomDev/installed-distributed-runtime-20260915'
SSH=['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=8']

def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
assert digest(SOURCE/'manifest.json')=='9b5f0702759ee6947c3876a6515545e3152c80d7306557ca745cb755cbe3990b'
for member in json.loads((SOURCE/'manifest.json').read_text())['members']:
    assert digest(SOURCE/member['path'])==member['sha256']
OUT.mkdir(mode=0o700)
REMOTE_CODE=r'''
from pathlib import Path
import base64,hashlib,json,os,subprocess,sys
x=json.load(sys.stdin); root=Path(x['remote']); staging=root/'setup'
assert hashlib.sha256((root/'darkbloom').read_bytes()).hexdigest()==x['providerSHA256']
backup=json.loads((root/'operator-state/configuration-before.json').read_text())
selected=Path(backup['selectedProviderConfig'])
assert selected.exists()==backup['existed']
if selected.exists(): assert hashlib.sha256(selected.read_bytes()).hexdigest()==backup['sha256'],'Default config changed since backup'
staging.mkdir(mode=0o700)
for name in ['configure.json','capability.json']:
 raw=base64.b64decode(x['files'][name]['data'],validate=True)
 assert hashlib.sha256(raw).hexdigest()==x['files'][name]['sha256']
 path=staging/name; path.write_bytes(raw); path.chmod(0o600)
command=[str(root/'darkbloom'),'cluster','configure','--input',str(staging/'configure.json'),'--capability',str(staging/'capability.json'),'--capability-sha256',x['files']['capability.json']['sha256'],'--json']
result=subprocess.run(command,capture_output=True,text=True,timeout=30)
print(json.dumps({'command':command,'exitCode':result.returncode,'stdout':result.stdout,'stderr':result.stderr,'defaultConfigAfterSHA256':hashlib.sha256(selected.read_bytes()).hexdigest() if selected.exists() else None,'defaultConfigAfterMode':oct(selected.stat().st_mode&0o777) if selected.exists() else None}))
sys.exit(result.returncode)
'''
for role,host in [('leader','darkbloom-24'),('follower','darkbloom-48')]:
    value=json.loads((SOURCE/(role+'.template.json')).read_text())
    assert value['role']==role and value['memberID']==host
    for peer in value['peers']:
        for field,name in [('ownerExecutable','darkbloom'),('workerExecutable','darkbloom-cluster-worker')]:
            assert peer[field]=='/UNRESOLVED_PRODUCT_INSTALL_ROOT/'+name
            peer[field]=REMOTE+'/'+name
    data=(json.dumps(value,sort_keys=True,separators=(',',':'))+'\n').encode()
    target=OUT/(role+'.configure.json');target.write_bytes(data);target.chmod(0o600)
    cap=(SOURCE/'capability.json').read_bytes()
    payload={'remote':REMOTE,'providerSHA256':'bf3f5f182083488c40fef46807adb07d78f9df6b8e14e5a78a21377c98b97001','files':{name:{'data':base64.b64encode(raw).decode(),'sha256':hashlib.sha256(raw).hexdigest()} for name,raw in [('configure.json',data),('capability.json',cap)]}}
    result=subprocess.run(SSH+[host,shlex.join(['/usr/bin/python3','-c',REMOTE_CODE])],input=json.dumps(payload),capture_output=True,text=True,timeout=45)
    (OUT/(host+'.configuration.json')).write_text(json.dumps({'exitCode':result.returncode,'stdout':result.stdout,'stderr':result.stderr},indent=2)+'\n')
    print(json.dumps({'host':host,'exitCode':result.returncode,'configureOutput':json.loads(result.stdout) if result.stdout else None}),flush=True)
    assert result.returncode==0,result.stderr
