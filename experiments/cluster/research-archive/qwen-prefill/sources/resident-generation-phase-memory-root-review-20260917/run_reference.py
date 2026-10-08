"""Bounded, separately invoked physical reference phases with retained logs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
REFERENCE = ROOT.parent / 'resident-generation-phase-memory-draft-20260917/Experiment/reference'
PIN = '2a99a4e666c03ce4ef895c642dd34455e5439a672a86e28b04b94c28322fd7ab'
sys.path.insert(0, str(ROOT.parent / 'cluster-native-shared-hardware-go-qualification-draft-20260917'))
from check_process import run_owned

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('action', choices=['copy', 'run', 'collect'])
    action = parser.parse_args().action
    if sha(REFERENCE/'manifest.json') != PIN: raise ValueError('Reviewed reference changed')
    for name, row in json.loads((REFERENCE/'manifest.json').read_bytes())['files'].items():
        path = REFERENCE/name
        if path.is_symlink() or path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
            raise ValueError('Reference closure changed')
    if json.loads((ROOT/'arguments-1/receipt.json').read_bytes())['status'] != 'passed':
        raise ValueError('Local qualification must complete')
    if action == 'run':
        if json.loads((ROOT/'reference-copy-1/receipt.json').read_bytes())['status'] != 'passed':
            raise ValueError('Actual copy verification required')
    output = ROOT/('reference-'+action+'-1'); output.mkdir(mode=0o700)
    receipt = dict(status='failed', action=action, referenceManifestSHA256=PIN)
    try:
        receipt['execution'] = run_owned(['/usr/bin/python3','-B',str(REFERENCE/'run_physical.py'),action],
            output, 'execution', {'copy':60,'run':450,'collect':60}[action])
        result = REFERENCE/('physical-'+action+'-1/execution.json')
        if json.loads(result.read_bytes()).get('passed') is not True: raise ValueError('Physical phase failed')
        receipt.update(status='passed', resultSHA256=sha(result))
    finally:
        with (output/'receipt.json').open('x') as stream:
            json.dump(receipt,stream,indent=2,sort_keys=True);stream.write('\n')
    print(json.dumps(receipt,sort_keys=True))

if __name__ == '__main__':
    os.umask(0o077); main()
