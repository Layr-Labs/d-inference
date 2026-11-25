"""Root-owned exact Ready eligibility correction and complete client qualification."""
import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT.parent / 'cluster-member-ready-eligibility-correction-20260917'
OUTPUT = ROOT.parent / 'cluster-member-ready-eligibility-checks-20260917'
EXPECTED = 'c43faeb94089f431a15f14c20f5a33060b8a16b652bbae461825a44e105a5654'
sys.path.insert(0, str(SOURCE))
from check_process import run_owned

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def verify():
    assert sha(SOURCE / 'manifest.json') == EXPECTED
    for row in json.loads((SOURCE / 'manifest.json').read_bytes())['files']:
        path = SOURCE / row['path']
        assert not path.is_symlink() and path.stat().st_size == row['bytes'] and sha(path) == row['sha256']

os.umask(0o077)
phases = ['source', 'prepare', 'helper', 'tests', 'build']
parser = argparse.ArgumentParser(allow_abbrev=False)
parser.add_argument('phase', choices=phases)
args = parser.parse_args()
verify()
if args.phase != 'source':
    record = json.loads((ROOT / ('ready-' + phases[phases.index(args.phase)-1] + '-1/receipt.json')).read_bytes())
    assert record['status'] == 'passed' and record['manifestSHA256'] == EXPECTED
command = next(row for row in json.loads((SOURCE / 'commands.json').read_bytes())['commands'] if row['step'] == args.phase)['argv']
assert command[0] == 'python3'
command[0] = '/usr/bin/python3'
out = ROOT / ('ready-' + args.phase + '-1')
out.mkdir(mode=0o700)
receipt = dict(status='failed', phase=args.phase, manifestSHA256=EXPECTED)
try:
    bounds = dict(source=30, prepare=150, helper=1200, tests=960, build=960)
    receipt['execution'] = run_owned(command, out, 'execution', bounds[args.phase])
    verify()
    if args.phase != 'source':
        result = OUTPUT / ('preparation.json' if args.phase == 'prepare' else args.phase + '-1/checks.json')
        record = json.loads(result.read_bytes())
        assert record['wrapperManifestSHA256'] == EXPECTED if args.phase == 'prepare' else record['passed'] is True
        receipt['resultSHA256'] = sha(result)
    receipt['status'] = 'passed'
finally:
    with (out / 'receipt.json').open('x') as stream:
        json.dump(receipt, stream, indent=2, sort_keys=True)
        stream.write('\n')
print(json.dumps(receipt, sort_keys=True))
