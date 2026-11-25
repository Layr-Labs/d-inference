"""Root-owned sequential qualification of the exact actor-boundary correction."""
import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT.parent / 'cluster-member-install-actor-correction-20260917'
OUTPUT = ROOT.parent / 'cluster-member-install-actor-checks-20260917'
EXPECTED = '0f8d48a333f6e6c4be2a0be373ad28ef82bce06b33a792ef243e311f448053cb'
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
parser = argparse.ArgumentParser(allow_abbrev=False)
phases = ['prepare', 'tests', 'build']
parser.add_argument('phase', choices=phases)
args = parser.parse_args()
verify()
if args.phase != 'prepare':
    prior = ROOT / ('actor-' + phases[phases.index(args.phase) - 1] + '-1/receipt.json')
    record = json.loads(prior.read_bytes())
    assert record['status'] == 'passed' and record['manifestSHA256'] == EXPECTED
command = next(row for row in json.loads((SOURCE / 'commands.json').read_bytes())['commands'] if row['step'] == args.phase)
out = ROOT / ('actor-' + args.phase + '-1')
out.mkdir(mode=0o700)
receipt = dict(status='failed', phase=args.phase, manifestSHA256=EXPECTED)
try:
    receipt['execution'] = run_owned(command['argv'], out, 'execution', command['outerBoundSeconds'])
    verify()
    result = OUTPUT / ('preparation.json' if args.phase == 'prepare' else args.phase + '-1/checks.json')
    record = json.loads(result.read_bytes())
    assert record['wrapperManifestSHA256'] == EXPECTED if args.phase == 'prepare' else record['passed'] is True
    receipt.update(status='passed', resultSHA256=sha(result))
finally:
    with (out / 'receipt.json').open('x') as stream:
        json.dump(receipt, stream, indent=2, sort_keys=True)
        stream.write('\n')
print(json.dumps(receipt, sort_keys=True))
