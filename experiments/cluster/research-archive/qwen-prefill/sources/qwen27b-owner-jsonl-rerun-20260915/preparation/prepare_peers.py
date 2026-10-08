"""Root-owned config-only correction, exact installation checks and cache preparation."""
from pathlib import Path
import base64
import hashlib
import json
import shlex
import subprocess
import sys

BASE = Path(__file__).resolve().parent.parent
OLD = BASE.parent / 'qwen27b-owner-physical-parent-draft-20260915'
sys.path.insert(0, str(BASE))
from parent_settings import SSH

def main():
    output = BASE / 'preflight-1'
    output.mkdir(mode=0o700, exist_ok=False)
    old = json.loads((OLD / 'deployment.json').read_bytes())
    new = json.loads((BASE / 'deployment.json').read_bytes())
    preflight = (OLD / 'preflight-1/remote-preflight.py').read_text()
    install = Path(__file__).with_name('replace_owner_configuration.py').read_text()
    rows = [[cell.strip().strip('`') for cell in line.strip().strip('|').split('|')]
            for line in (BASE.parent.parent / 'machines/CREDENTIALS.private.md').read_text().splitlines() if line.startswith('|')]
    password = rows[2][[cell.lower() for cell in rows[0]].index('password')]
    def invoke(host, name, command, content, timeout):
        result = subprocess.run(SSH + [host, shlex.join(command)], input=content,
                                capture_output=True, timeout=timeout)
        out = result.stdout.replace(password.encode(), b'[REDACTED]')
        err = result.stderr.replace(password.encode(), b'[REDACTED]')
        (output / (host + '-' + name + '.stdout')).write_bytes(out)
        (output / (host + '-' + name + '.stderr')).write_bytes(err)
        if result.returncode:
            raise RuntimeError(host + ' ' + name + ' exit ' + str(result.returncode))
        return out
    for rank, host in enumerate(['darkbloom-24', 'darkbloom-48']):
        invoke(host, 'before', ['/usr/bin/python3', '-B', '-c', preflight], json.dumps(old['ranks'][rank]).encode(), 45)
        source = BASE / ('configuration/owner-rank' + str(rank) + '.json')
        before = OLD / ('configuration/owner-rank' + str(rank) + '.json')
        packet = {'configurationBase64': base64.b64encode(source.read_bytes()).decode(),
                  'beforeSHA256': hashlib.sha256(before.read_bytes()).hexdigest(),
                  'afterSHA256': hashlib.sha256(source.read_bytes()).hexdigest()}
        invoke(host, 'replace', ['/usr/bin/python3', '-B', '-c', install], json.dumps(packet).encode(), 20)
        invoke(host, 'purge', ['/usr/bin/sudo', '-k', '-S', '-p', '', '/usr/sbin/purge'], (password + '\n').encode(), 45)
        result = json.loads(invoke(host, 'after', ['/usr/bin/python3', '-B', '-c', preflight], json.dumps(new['ranks'][rank]).encode(), 45))
        print(json.dumps({'host': host, 'verifiedFiles': len(result['verified']), 'evidenceEmpty': result['evidenceEmpty'], 'journalBytes': result['journal']['bytes'], 'resource': result['resource']}), flush=True)

if __name__ == '__main__':
    main()
