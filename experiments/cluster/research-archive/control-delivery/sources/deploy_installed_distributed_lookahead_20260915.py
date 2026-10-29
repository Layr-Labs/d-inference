from pathlib import Path
import hashlib, json, shlex, subprocess, sys

ROOT = Path('/Users/developer/DarkbloomDev/cluster-research')
BUNDLE = ROOT / 'installed-distributed-lookahead-product-bundle-20260915'
ATTEMPT = sys.argv[1] if len(sys.argv) > 1 else '1'
assert ATTEMPT.isdigit()
HOSTS = sys.argv[2:] or ['darkbloom-24', 'darkbloom-48']
assert HOSTS and all(host in ['darkbloom-24', 'darkbloom-48'] for host in HOSTS)
OUT = ROOT / ('installed-distributed-lookahead-deployment-20260915' if ATTEMPT == '1' else 'installed-distributed-lookahead-deployment-attempt' + ATTEMPT + '-20260915')
REMOTE = '/Users/developer/DarkbloomDev/installed-distributed-lookahead-runtime-20260915'
SSH = ['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8']
PREFLIGHT = r'''
from pathlib import Path
import hashlib,json,os,shutil,stat,subprocess,sys
root=Path(sys.argv[1]); home=Path('/Users/gaj')
assert not root.exists() and root.parent.is_dir() and not root.parent.is_symlink()
ps=subprocess.check_output(['/bin/ps','-axo','pid=,comm='],text=True)
active=[line.strip() for line in ps.splitlines() if len(line.split(maxsplit=1))==2 and Path(line.split(maxsplit=1)[1]).name in ['darkbloom','darkbloom-cluster-worker','darkbloom-owner-qualification']]
assert not active, active
pid_file=home/'.darkbloom/provider.pid'
pid_state={'exists':pid_file.exists()}
if pid_file.exists():
 assert pid_file.is_file() and not pid_file.is_symlink() and pid_file.stat().st_size<128
 value=pid_file.read_text().strip()
 assert value.isdigit() and int(value)>1
 try: os.kill(int(value),0)
 except ProcessLookupError: pid_state['live']=False
 else: raise RuntimeError('Existing provider PID is live; refusing implicit termination')
journals=[]
candidates=list((home/'DarkbloomDev').glob('owner-*/lease/*'))+[home/'.darkbloom/cluster-device/native-device.lease']
for path in candidates:
 if path.exists() and ('journal' in path.name or path.name=='native-device.lease'):
  assert path.is_file() and not path.is_symlink() and path.stat().st_size==0,str(path)
  journals.append(str(path))
root.mkdir(mode=0o700); backup=root/'operator-state'; backup.mkdir(mode=0o700)
config_candidates=[home/'.config/darkbloom/provider.toml',home/'Library/Application Support/darkbloom/provider.toml',home/'.config/eigeninference/provider.toml',home/'Library/Application Support/eigeninference/provider.toml']
selected=next((p for p in config_candidates if p.exists()),config_candidates[0])
before={'selectedProviderConfig':str(selected),'existed':selected.exists()}
if selected.exists():
 st=selected.lstat(); assert stat.S_ISREG(st.st_mode) and st.st_uid==os.geteuid() and st.st_size<=1048576
 raw=selected.read_bytes(); saved=backup/'provider.toml.before'; saved.write_bytes(raw); saved.chmod(0o600)
 before.update(sha256=hashlib.sha256(raw).hexdigest(),bytes=len(raw),mode=stat.S_IMODE(st.st_mode))
for name in ['local.json','local_token','provider.pid']:
 path=home/'.darkbloom'/name
 if path.exists():
  assert path.is_file() and not path.is_symlink() and path.stat().st_size<=65536
  saved=backup/(name+'.before'); shutil.copyfile(path,saved); saved.chmod(0o600)
(backup/'configuration-before.json').write_text(json.dumps(before,indent=2)+'\n')
(backup/'configuration-before.json').chmod(0o600)
print(json.dumps({'root':str(root),'active':active,'providerPID':pid_state,'configurationBefore':before,'zeroJournals':journals,'diskFreeBytes':shutil.disk_usage(root).free}))
'''
VERIFY = r'''
from pathlib import Path
import hashlib,json,os,stat,subprocess,sys
root=Path(sys.argv[1]); manifest=json.loads((root/'bundle.json').read_text()); checks=[]
for item in manifest['files']:
 path=root/item['path']; st=path.lstat()
 assert stat.S_ISREG(st.st_mode) and st.st_uid==os.geteuid() and not path.is_symlink()
 raw=path.read_bytes(); actual=hashlib.sha256(raw).hexdigest()
 assert actual==item['sha256'] and len(raw)==item['bytes'],str(path)
 assert not item['executable'] or st.st_mode&0o100
 checks.append({'path':item['path'],'sha256':actual,'bytes':len(raw)})
help_result=subprocess.run([str(root/'darkbloom'),'cluster','worker-owner','--help'],capture_output=True,timeout=15)
assert help_result.returncode==0 and b'--stdio' in help_result.stdout,(help_result.returncode,help_result.stderr.decode())
worker_hash=next(item['sha256'] for item in manifest['files'] if item['path']=='darkbloom-cluster-worker')
result=subprocess.run([str(root/'darkbloom-cluster-worker'),'--describe-runtime','--config','/Users/developer/DarkbloomDev/models/Qwen3.5-9B/config.json','--manifest','/Users/developer/DarkbloomDev/models/Qwen3.5-9B/manifest.json','--expected-executable-sha256',worker_hash],capture_output=True,timeout=15)
assert result.returncode==0,(result.returncode,result.stderr.decode())
assert result.stdout==(root/'capability.json').read_bytes(),'Installed native descriptor differs'
print(json.dumps({'verified':checks,'ownerHelpExitCode':help_result.returncode,'nativeMetadataExitCode':result.returncode,'descriptorSHA256':hashlib.sha256(result.stdout).hexdigest(),'nativeGenerationExecuted':False}))
'''

def remote(host, code, *args):
    return subprocess.run(SSH+[host,shlex.join(['/usr/bin/python3','-c',code,*args])],capture_output=True,text=True,timeout=45)

OUT.mkdir(mode=0o700)
manifest=json.loads((BUNDLE/'bundle.json').read_text())
for item in manifest['files']:
    assert hashlib.sha256((BUNDLE/item['path']).read_bytes()).hexdigest()==item['sha256']
for host in HOSTS:
    result=remote(host,PREFLIGHT,REMOTE)
    (OUT/(host+'.preflight.json')).write_text(json.dumps({'exitCode':result.returncode,'stdout':result.stdout,'stderr':result.stderr},indent=2)+'\n')
    assert result.returncode==0,result.stderr
    result=subprocess.run(['scp','-q','-p','-r','-o','BatchMode=yes','-o','ConnectTimeout=8',str(BUNDLE)+'/.',host+':'+REMOTE+'/'],capture_output=True,text=True,timeout=240)
    (OUT/(host+'.copy.json')).write_text(json.dumps({'exitCode':result.returncode,'stderr':result.stderr},indent=2)+'\n')
    assert result.returncode==0,result.stderr
    result=remote(host,VERIFY,REMOTE)
    (OUT/(host+'.verification.json')).write_text(json.dumps({'exitCode':result.returncode,'stdout':result.stdout,'stderr':result.stderr},indent=2)+'\n')
    assert result.returncode==0,result.stderr
    print(json.dumps({'host':host,'installed':REMOTE,'verified':True,'nativeGenerationExecuted':False}),flush=True)
