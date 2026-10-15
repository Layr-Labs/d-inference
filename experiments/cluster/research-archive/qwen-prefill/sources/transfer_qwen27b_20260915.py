from pathlib import Path
import hashlib, json, os, shlex, signal, subprocess, sys, time

ROOT = Path('/Users/developer/DarkbloomDev/cluster-research/qwen27b-remote-model-preparation-20260915')
SOURCE = Path('/Users/developer/DarkbloomDev/models/Qwen3.8-27B')
HOSTS = {'darkbloom-24': ('172.16.40.199', '192.0.2.250'),
         'darkbloom-48': ('172.16.40.240', '192.0.2.223')}
host = sys.argv[1]
address, trusted_alias = HOSTS[host]
out = ROOT / host
out.mkdir(mode=0o700)
ssh = ['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8',
       '-o', 'StrictHostKeyChecking=yes', '-o', 'ControlPath=none',
       '-o', 'HostName=' + address, '-o', 'HostKeyAlias=' + trusted_alias]
manifest_sha = 'd1239a5bc6d26d5ce4bf87f22270e3a703f4942e3d0d779948b4f65410df6dcc'
assert hashlib.sha256((SOURCE / 'manifest.json').read_bytes()).hexdigest() == manifest_sha
assert json.loads((ROOT / 'local-verification.json').read_text())['wholePayloadVerified'] is True

def remote(code, timeout):
    return subprocess.run(ssh + [host, shlex.join(['/usr/bin/python3', '-B', '-c', code])],
                          capture_output=True, text=True, timeout=timeout)

preflight = remote("""
from pathlib import Path
import json,shutil,subprocess
p=Path('/Users/developer/DarkbloomDev/models/Qwen3.8-27B')
assert not p.exists() and p.parent.is_dir() and not p.parent.is_symlink()
free=shutil.disk_usage(p.parent).free
assert free>2*16320415757+16*1024**3
ps=subprocess.check_output(['/bin/ps','-axo','pid=,comm='],text=True)
active=[line for line in ps.splitlines() if len(line.split(maxsplit=1))==2 and Path(line.split(maxsplit=1)[1]).name in ['darkbloom','darkbloom-cluster-worker']]
assert not active,active
p.mkdir(mode=0o700)
print(json.dumps({'created':str(p),'diskFreeBytes':free,'activeInference':active}))
""", 20)
(out / 'preflight.json').write_text(json.dumps({'exitCode': preflight.returncode,
    'stdout': preflight.stdout, 'stderr': preflight.stderr}, indent=2) + '\n')
assert preflight.returncode == 0, preflight.stderr
command = ['/usr/bin/rsync', '-rt', '--partial', '--stats', '--progress', '--timeout=120',
           '--files-from=' + str(ROOT / 'files.txt'), '-e', shlex.join(ssh),
           str(SOURCE) + '/', host + ':' + str(SOURCE) + '/']
started = time.monotonic()
receipt = {'host': host, 'transport': 'LAN SSH with existing Tailscale host-key identity',
           'address': address, 'command': command, 'modelExecution': False}
with (out / 'rsync.stdout').open('xb') as stdout, (out / 'rsync.stderr').open('xb') as stderr:
    child = subprocess.Popen(command, stdout=stdout, stderr=stderr, start_new_session=True)
    receipt['pid'] = child.pid
    (out / 'launch.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'host': host, 'rsyncPID': child.pid, 'state': 'copying'}), flush=True)
    try:
        receipt['exitCode'] = child.wait(timeout=5400)
    except BaseException as error:
        receipt['error'] = type(error).__name__ + ': ' + str(error)
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)
            try: child.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL); child.wait(timeout=5)
        receipt['exitCode'] = child.returncode
    receipt['elapsedSeconds'] = time.monotonic() - started
    (out / 'copy.json').write_text(json.dumps(receipt, indent=2) + '\n')
assert receipt['exitCode'] == 0, receipt
verification = remote("""
from pathlib import Path
import hashlib,json,time
p=Path('/Users/developer/DarkbloomDev/models/Qwen3.8-27B');start=time.monotonic()
raw=(p/'manifest.json').read_bytes()
assert hashlib.sha256(raw).hexdigest()=='d1239a5bc6d26d5ce4bf87f22270e3a703f4942e3d0d779948b4f65410df6dcc'
m=json.loads(raw);verified=[]
for item in m['files']:
 f=p/item['path'];assert f.is_file() and not f.is_symlink() and f.stat().st_size==item['size_bytes']
 h=hashlib.sha256()
 with f.open('rb') as stream:
  for block in iter(lambda:stream.read(8*1024*1024),b''):h.update(block)
 assert h.hexdigest()==item['sha256'],str(f)
 verified.append({'path':item['path'],'sha256':h.hexdigest(),'bytes':f.stat().st_size})
assert len(verified)==14 and sum(v['bytes'] for v in verified)==16320415757
print(json.dumps({'verifiedFiles':verified,'wholePayloadVerified':True,'elapsedSeconds':time.monotonic()-start,'modelExecution':False}))
""", 300)
(out / 'verification.json').write_text(json.dumps({'exitCode': verification.returncode,
    'stdout': verification.stdout, 'stderr': verification.stderr}, indent=2) + '\n')
assert verification.returncode == 0, verification.stderr
print(json.dumps({'host': host, 'state': 'verified', 'files': 14,
                  'payloadBytes': 16320415757, 'copySeconds': receipt['elapsedSeconds']}), flush=True)
