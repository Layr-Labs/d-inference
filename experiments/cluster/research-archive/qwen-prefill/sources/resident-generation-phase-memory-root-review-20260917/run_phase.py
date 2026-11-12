"""Root-owned local qualification, with regular controller logs and phase gates."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT.parent / 'resident-generation-phase-memory-draft-20260917'
PIN = '31eb155a8cc15dd2e0ffa22e50dfd7a05c382b24172e02c767b990901f467fd5'
HELPERS = ROOT.parent / 'cluster-native-shared-hardware-go-qualification-draft-20260917'
sys.path.insert(0, str(HELPERS))
from check_process import run_owned

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    phases = ['source', 'cpu', 'prepare', 'native', 'package', 'arguments']
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('phase', choices=phases)
    args = parser.parse_args()
    if sha(SOURCE / 'manifest.json') != PIN:
        raise ValueError('Reviewed source manifest changed')
    members = json.loads((SOURCE / 'manifest.json').read_bytes())['members']
    for row in members:
        path = SOURCE / row['path']
        if path.is_symlink() or path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
            raise ValueError('Frozen source changed: ' + row['path'])
    index = phases.index(args.phase)
    if index:
        prior = json.loads((ROOT / (phases[index-1] + '-1/receipt.json')).read_bytes())
        if prior['status'] != 'passed' or prior['sourceManifestSHA256'] != PIN:
            raise ValueError('Previous actual phase must pass')
    specification = {
        'source': ('check_source.py', [], 30, None),
        'cpu': ('Build/check_cpu.py', ['1'], 500, 'Build/cpu-1/receipt.json'),
        'prepare': ('Build/prepare.py', [], 150, 'Build/prepare-1/receipt.json'),
        'native': ('Build/build_native.py', ['1'], 960, 'Build/native-1/receipt.json'),
        'package': ('Build/package_native.py', ['1'], 90, 'Build/runtime-bundle-1/bundle.json'),
        'arguments': ('Build/check_arguments.py', ['1'], 90, 'Build/arguments-1/receipt.json'),
    }
    script, extra, timeout, result = specification[args.phase]
    output = ROOT / (args.phase + '-1')
    output.mkdir(mode=0o700)
    receipt = dict(status='failed', phase=args.phase, sourceManifestSHA256=PIN,
                   modelOrRemoteExecuted=False)
    try:
        command = ['/usr/bin/python3', '-B', str(SOURCE / script), *extra]
        receipt['execution'] = run_owned(command, output, 'execution', timeout)
        if result:
            data = json.loads((SOURCE / result).read_bytes())
            if args.phase != 'package' and data.get('passed') is not True:
                raise ValueError('Child phase did not pass')
            receipt['resultSHA256'] = sha(SOURCE / result)
        receipt['status'] = 'passed'
    finally:
        with (output / 'receipt.json').open('x') as stream:
            json.dump(receipt, stream, indent=2, sort_keys=True)
            stream.write('\n')
    print(json.dumps(receipt, sort_keys=True))

if __name__ == '__main__':
    os.umask(0o077)
    main()
