"""Root-owned test-only correction qualification, retaining every phase log."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT.parent / 'cluster-native-numerical-ready-fixture-correction-20260917'
HELPER = ROOT.parent / 'cluster-native-numerical-provider-build-draft-20260917'
PIN = '6226fcc80ae2d3f28b47b4f88ad760bdb5fc1d9b88731c1cd1d8938153923ebc'
sys.path.insert(0, str(HELPER))
from check_process import run_owned

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('phase', choices=['source','prepare','tests','build'])
    args = parser.parse_args()
    if sha(SOURCE/'manifest.json') != PIN: raise ValueError('Reviewed fixture changed')
    previous = {'prepare':'source','tests':'prepare','build':'tests'}.get(args.phase)
    if previous:
        record = json.loads((ROOT/(previous+'-1/receipt.json')).read_bytes())
        if record['status'] != 'passed' or record['manifestSHA256'] != PIN:
            raise ValueError('Matching prior phase required')
    out = ROOT/(args.phase+'-1'); out.mkdir(mode=0o700)
    record = dict(status='failed', phase=args.phase, manifestSHA256=PIN)
    try:
        record['execution'] = run_owned(['/usr/bin/python3','-B',str(SOURCE/'retry.py'),args.phase],
            out,'execution',{'source':30,'prepare':120,'tests':960,'build':960}[args.phase])
        if args.phase != 'source':
            result = SOURCE/('preparation-1/receipt.json' if args.phase == 'prepare' else args.phase+'-1/checks.json')
            if json.loads(result.read_bytes())['passed'] is not True: raise ValueError('Actual phase failed')
            record['resultSHA256'] = sha(result)
        record['status'] = 'passed'
    finally:
        with (out/'receipt.json').open('x') as stream:
            json.dump(record,stream,indent=2,sort_keys=True);stream.write('\n')
    print(json.dumps(record,sort_keys=True))

if __name__ == '__main__':
    os.umask(0o077); main()
