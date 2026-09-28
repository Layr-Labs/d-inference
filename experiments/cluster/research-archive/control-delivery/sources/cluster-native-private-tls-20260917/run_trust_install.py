"""Bounded trust setup on the exact development Macs; credentials stay on stdin."""
import argparse
import base64
import hashlib
import json
import os
import shlex
import signal
import stat
import subprocess
import time
from pathlib import Path

BASE = Path(__file__).resolve().parent
SCRIPT = BASE / 'install_host_trust.py'
KNOWN = BASE.parent / 'owner-ssh-preflight-20260915/known_hosts'
TARGETS = {'local': (None, 36), 'rank0': ('developer@192.0.2.250', 24), 'rank1': ('developer@192.0.2.223', 48)}

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('target', choices=TARGETS)
    args = parser.parse_args()
    assert sha(SCRIPT) == 'e0edf6cc50ece95203b78c3b3841c18e62c653bb84103573d63ed4a671199a2e'
    assert sha(KNOWN) == '89a73d7ca9fe16a0c1aeb0fa6cfa640ff37a02d4a2d21114e7ad5fca089443ed'
    credential = BASE.parent.parent / 'machines/CREDENTIALS.private.md'
    info = credential.lstat()
    assert stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o600
    rows = [[cell.strip().strip('`') for cell in line.strip().strip('|').split('|')]
            for line in credential.read_text().splitlines() if line.startswith('|')]
    secret = (rows[2][[cell.lower() for cell in rows[0]].index('password')] + '\n').encode()
    host, memory = TARGETS[args.target]
    public = dict(memoryBytes=memory * 1024**3,
                  ca=base64.b64encode((BASE / 'development-ca-1/ca.crt').read_bytes()).decode(),
                  leaf=base64.b64encode((BASE / 'development-ca-1/server.crt').read_bytes()).decode())
    command = ['/usr/bin/python3', '-B', str(SCRIPT)]
    if host is not None:
        remote = ['/usr/bin/python3', '-B', '-c', SCRIPT.read_text()]
        command = ['/usr/bin/ssh', '-T', '-S', 'none', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
                   '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=2', '-o', 'IdentitiesOnly=yes',
                   '-o', 'StrictHostKeyChecking=yes', '-o', 'UserKnownHostsFile=' + str(KNOWN),
                   '-i', '/Users/developer/.ssh/id_ed25519_darkbloom_dev', host, shlex.join(remote)]
    out = BASE / ('install-' + args.target + '-1')
    out.mkdir(mode=0o700)
    record = dict(status='failed', target=args.target, remoteScriptSHA256=sha(SCRIPT), credentialPrinted=False)
    started = time.monotonic()
    child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    record['pid'] = child.pid
    try:
        try:
            stdout, stderr = child.communicate(secret + json.dumps(public).encode(), timeout=180)
        except BaseException:
            if child.returncode is None:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                    record['killedOwnedGroup'] = True
                except ProcessLookupError:
                    pass
            child.communicate(timeout=5)
            raise
        for name, raw in [('stdout', stdout), ('stderr', stderr)]:
            with (out / name).open('xb') as stream:
                stream.write(raw.replace(secret.rstrip(b'\n'), b'[REDACTED]'))
        assert len(stdout) + len(stderr) <= 131072 and child.returncode == 0 and not stderr
        result = json.loads(stdout)
        assert result['status'] == 'passed' and result['trustInstalled'] and result['osTrustValidated']
        record.update(status='passed', result=result)
    finally:
        record.update(exitCode=child.returncode, reaped=child.returncode is not None, elapsedSeconds=time.monotonic()-started)
        try:
            os.killpg(child.pid, 0)
            record['groupAbsent'] = False
        except ProcessLookupError:
            record['groupAbsent'] = True
        with (out / 'receipt.json').open('x') as stream:
            json.dump(record, stream, indent=2, sort_keys=True)
            stream.write('\n')
    assert record['reaped'] and record['groupAbsent'] and not record.get('killedOwnedGroup')
    print(json.dumps(record, sort_keys=True))

if __name__ == '__main__':
    os.umask(0o077)
    main()
