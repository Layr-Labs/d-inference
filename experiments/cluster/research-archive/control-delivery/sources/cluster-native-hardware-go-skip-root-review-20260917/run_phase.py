"""Run the exact maintenance-skip correction with retained regular logs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT.parent / 'cluster-native-hardware-go-maintenance-skip-correction-20260917'
PIN = '3fd6316e63474a5e7b3187bd8706cc8ecb8d817e3da5f4e35195ddf40b5f1481'
sys.path.insert(0, str(ROOT.parent / 'cluster-native-shared-hardware-go-qualification-draft-20260917'))
from check_process import run_owned

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    phases = ['source', 'parser', 'check', 'build']
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('phase', choices=phases)
    args = parser.parse_args()
    if sha(SOURCE / 'manifest.json') != PIN: raise ValueError('Reviewed manifest changed')
    for row in json.loads((SOURCE / 'manifest.json').read_bytes())['files']:
        path = SOURCE / row['path']
        if path.is_symlink() or path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
            raise ValueError('Frozen correction changed')
    index = phases.index(args.phase)
    if index:
        previous = json.loads((ROOT / (phases[index-1]+'-1/receipt.json')).read_bytes())
        if previous['status'] != 'passed' or previous['sourceManifestSHA256'] != PIN:
            raise ValueError('Previous actual phase must pass')
    output = ROOT / (args.phase+'-1'); output.mkdir(mode=0o700)
    command = ['/usr/bin/python3', '-B', str(SOURCE / {
        'source': 'successor.py', 'parser': 'test_command_results.py',
        'check': 'run.py', 'build': 'run.py'}[args.phase])]
    if args.phase in ('check', 'build'): command += ['--phase', args.phase, '--attempt', '1']
    receipt = dict(status='failed', phase=args.phase, sourceManifestSHA256=PIN)
    try:
        receipt['execution'] = run_owned(command, output, 'execution',
            {'source':30, 'parser':30, 'check':1900, 'build':660}[args.phase])
        if args.phase in ('check', 'build'):
            result = SOURCE / (args.phase+'-1/checks.json')
            if json.loads(result.read_bytes()).get('passed') is not True:
                raise ValueError('Actual phase failed')
            receipt['resultSHA256'] = sha(result)
        receipt['status'] = 'passed'
    finally:
        with (output/'receipt.json').open('x') as stream:
            json.dump(receipt, stream, indent=2, sort_keys=True); stream.write('\n')
    print(json.dumps(receipt, sort_keys=True))

if __name__ == '__main__':
    os.umask(0o077); main()
