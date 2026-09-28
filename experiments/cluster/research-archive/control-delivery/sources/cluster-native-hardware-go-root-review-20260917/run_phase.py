"""Root-reviewed private Go phases with regular logs and bounded ownership."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT.parent / 'cluster-native-shared-hardware-go-qualification-draft-20260917'
PIN = '332bb5d6dcb766ea59859b6564e6eba2129f0885fcdce6cd94283d4cb8eb1c51'
sys.path.insert(0, str(SOURCE))
from check_process import run_owned

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('phase', choices=['prepare', 'check', 'build'])
    args = parser.parse_args()
    if sha(SOURCE / 'manifest.json') != PIN: raise ValueError('Reviewed source changed')
    for row in json.loads((SOURCE / 'manifest.json').read_bytes())['files']:
        path = SOURCE / row['path']
        if path.is_symlink() or path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
            raise ValueError('Frozen member changed')
    previous = {'check': 'prepare', 'build': 'check'}.get(args.phase)
    if previous:
        prior = json.loads((ROOT / (previous+'-1/receipt.json')).read_bytes())
        if prior['status'] != 'passed' or prior['sourceManifestSHA256'] != PIN:
            raise ValueError('Actual previous phase required')
    out = ROOT / (args.phase+'-1'); out.mkdir(mode=0o700)
    record = dict(status='failed', phase=args.phase, sourceManifestSHA256=PIN)
    command = ['/usr/bin/python3', '-B', str(SOURCE / ('prepare.py' if args.phase == 'prepare' else 'run.py'))]
    if args.phase != 'prepare': command += ['--phase', args.phase, '--attempt', '1']
    try:
        record['execution'] = run_owned(command, out, 'execution', {'prepare':120,'check':1900,'build':660}[args.phase])
        result = SOURCE / ('preparation/receipt.json' if args.phase == 'prepare' else args.phase+'-1/checks.json')
        if json.loads(result.read_bytes())['passed'] is not True: raise ValueError('Actual phase failed')
        record.update(status='passed', resultSHA256=sha(result))
    finally:
        with (out/'receipt.json').open('x') as stream:
            json.dump(record,stream,indent=2,sort_keys=True);stream.write('\n')
    print(json.dumps(record,sort_keys=True))

if __name__ == '__main__':
    os.umask(0o077); main()
