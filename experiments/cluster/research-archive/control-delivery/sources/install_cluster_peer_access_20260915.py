from pathlib import Path
import base64, hashlib, json, os, shlex, subprocess

ROOT = Path('/Users/developer/DarkbloomDev/cluster-research/installed-cluster-access-20260915')
ROOT.mkdir(mode=0o700)
SSH = ['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5']
peers = [('darkbloom-24', '192.0.2.250'), ('darkbloom-48', '192.0.2.223')]
generate = r'''
from pathlib import Path
import hashlib,json,os,stat,subprocess
folder=Path('/Users/developer/.ssh');folder.mkdir(mode=0o700,exist_ok=True)
assert not folder.is_symlink() and folder.stat().st_uid==os.geteuid()
key=folder/'id_ed25519_darkbloom_cluster';public=key.with_suffix('.pub')
created=False
if not key.exists() and not public.exists():
 subprocess.run(['/usr/bin/ssh-keygen','-q','-t','ed25519','-N','','-C','darkbloom-cluster-20260915','-f',str(key)],check=True)
 created=True
info=key.lstat();assert stat.S_ISREG(info.st_mode) and info.st_uid==os.geteuid() and info.st_mode&0o077==0 and info.st_nlink==1
parts=public.read_text().strip().split();assert len(parts)==3 and parts[0]=='ssh-ed25519'
host=Path('/etc/ssh/ssh_host_ed25519_key.pub').read_text().strip().split()
assert host[0]=='ssh-ed25519'
print(json.dumps({'created':created,'identityFile':str(key),'publicKey':' '.join(parts),'hostPublicKey':' '.join(host[:2])}))
'''
install = r'''
from pathlib import Path
import fcntl,hashlib,json,os,stat,sys
x=json.load(sys.stdin);folder=Path('/Users/developer/.ssh');target=folder/'darkbloom_cluster_known_hosts'
known=x['knownHosts'].encode();assert len(known)<4096
if target.exists():
 assert target.read_bytes()==known and not target.is_symlink()
else:
 fd=os.open(target,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
 with os.fdopen(fd,'wb') as out:out.write(known);out.flush();os.fsync(out.fileno())
auth=folder/'authorized_keys';fd=os.open(auth,os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW|os.O_CLOEXEC,0o600)
try:
 fcntl.flock(fd,fcntl.LOCK_EX);info=os.fstat(fd)
 assert stat.S_ISREG(info.st_mode) and info.st_uid==os.geteuid() and info.st_nlink==1 and info.st_mode&0o022==0 and info.st_size<1048576
 existing=os.read(fd,1048576);parts=x['peerPublicKey'].split();assert len(parts)==3 and parts[0]=='ssh-ed25519'
 key=parts[1].encode();present=any(key in line.split() for line in existing.splitlines())
 if not present:
  addition=(b'' if not existing or existing.endswith(b'\n') else b'\n')+('restrict '+x['peerPublicKey']+'\n').encode()
  os.lseek(fd,0,os.SEEK_END);assert os.write(fd,addition)==len(addition);os.fsync(fd)
finally:os.close(fd)
print(json.dumps({'knownHostsFile':str(target),'knownHostsSHA256':hashlib.sha256(known).hexdigest(),'peerPublicKeyAdded':not present,'authorizedKeyOptions':'restrict','privateKeyTransferred':False}))
'''
generated = []
for name, address in peers:
    result = subprocess.run(SSH + [name, shlex.join(['/usr/bin/python3', '-c', generate])], capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, (name, result.stderr)
    value = json.loads(result.stdout); generated.append(value)
    (ROOT / (name + '-key.json')).write_text(json.dumps(value, indent=2) + '\n')
known = ''.join(address + ' ' + value['hostPublicKey'] + '\n' for (_, address), value in zip(peers, generated))
for rank, (name, address) in enumerate(peers):
    payload = {'knownHosts': known, 'peerPublicKey': generated[1-rank]['publicKey']}
    result = subprocess.run(SSH + [name, shlex.join(['/usr/bin/python3', '-c', install])], input=json.dumps(payload), capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, (name, result.stderr)
    value = json.loads(result.stdout)
    (ROOT / (name + '-trust.json')).write_text(json.dumps(value, indent=2) + '\n')
    print(json.dumps({'host': name, **value}), flush=True)
for rank, (name, address) in enumerate(peers):
    command = ['/usr/bin/ssh','-F','/dev/null','-o','BatchMode=yes','-o','IdentitiesOnly=yes',
               '-o','StrictHostKeyChecking=yes','-o','UserKnownHostsFile=/Users/developer/.ssh/darkbloom_cluster_known_hosts',
               '-o','ConnectTimeout=5','-i','/Users/developer/.ssh/id_ed25519_darkbloom_cluster',
               'developer@' + peers[1-rank][1], '/usr/bin/true']
    result = subprocess.run(SSH + [name, shlex.join(command)], capture_output=True, text=True, timeout=15)
    record = {'source':name,'target':peers[1-rank][0],'exitCode':result.returncode,'stdout':result.stdout,'stderr':result.stderr,
              'authentication':'dedicated key with pinned host key; private keys remain on originating Macs'}
    (ROOT / (name + '-probe.json')).write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record), flush=True)
    assert result.returncode == 0
