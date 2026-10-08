"""Verify the selected unused timing case and prepare caches before measurement."""
from pathlib import Path
import argparse
import json
import shlex
import subprocess

ROOT = Path(__file__).resolve().parent

def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--case', required=True, choices=['cut4-timing', 'cut16-timing'])
    case = parser.parse_args().case
    output = ROOT / case
    output.mkdir(mode=0o700, exist_ok=False)
    code = (ROOT / 'remote-preflight.py').read_text()
    code = code.replace("assert all(not list((root/name/'evidence').iterdir()) for name in ('cut4-correctness','cut16-correctness','cut4-timing','cut16-timing'))",
                        "assert not list((root/value['selectedCase']/'evidence').iterdir())")
    (output / 'remote-preflight.py').write_text(code)
    rows = [[cell.strip().strip('`') for cell in line.strip().strip('|').split('|')]
            for line in (ROOT.parent.parent / 'machines/CREDENTIALS.private.md').read_text().splitlines() if line.startswith('|')]
    password = rows[2][[x.lower() for x in rows[0]].index('password')]
    for rank, host in enumerate(['darkbloom-24', 'darkbloom-48']):
        spec = json.loads((ROOT / f'rank{rank}-preflight-input.json').read_bytes())
        spec['selectedCase'] = case
        def run(label, args, data):
            command = ['/usr/bin/ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', host, shlex.join(args)]
            result = subprocess.run(command, input=data, capture_output=True, timeout=45)
            out = result.stdout.replace(password.encode(), b'[REDACTED]')
            err = result.stderr.replace(password.encode(), b'[REDACTED]')
            (output / (host + '-' + label + '.stdout')).write_bytes(out)
            (output / (host + '-' + label + '.stderr')).write_bytes(err)
            if result.returncode:
                raise RuntimeError(host + ' ' + label + ' failed; retained diagnostics')
            return out
        run('before', ['/usr/bin/python3', '-B', '-c', code], json.dumps(spec).encode())
        run('purge', ['/usr/bin/sudo', '-k', '-S', '-p', '', '/usr/sbin/purge'], (password + '\n').encode())
        after = json.loads(run('after', ['/usr/bin/python3', '-B', '-c', code], json.dumps(spec).encode()))
        print(json.dumps({'host': host, 'selectedCase': case, 'filesVerified': len(after['verified']),
                          'freeBytes': after['resource']['actualFreeBytes'], 'journalBytes': after['journal']['bytes']}), flush=True)

if __name__ == '__main__':
    main()
