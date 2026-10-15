import argparse
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT.parent / 'qwen9b-protected-ordinary-reference-draft-20260917'
EXPECTED = '4d19e5d7a6c7c21417e4233692ec89b9126cec7ac641c440b019e22def438938'
BINDING = 'eeff23029fb833f9e6e7d466903038bb103ae3c4bb45981bc366987221324c07'
sys.path.insert(0, str(SOURCE))
from check_process import run_owned

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def verify():
    assert sha(SOURCE / 'manifest.json') == EXPECTED
    for row in json.loads((SOURCE / 'manifest.json').read_bytes())['files']:
        path = SOURCE / row['path']
        assert not path.is_symlink() and path.stat().st_size == row['bytes'] and sha(path) == row['sha256']
    assert sha(ROOT / 'inputs-1/bound/binding.json') == BINDING

parser = argparse.ArgumentParser(allow_abbrev=False)
parser.add_argument('action', choices=['run', 'collect', 'collect-failed'])
args = parser.parse_args()
verify()
preflight = ROOT / 'preflight-1/receipt.json'
assert sha(preflight) == 'f2fb7d761bb1c8eb79fa4e706d286ffef384a23df5f81a5d26bab13b7e2ef599'
assert json.loads(preflight.read_bytes())['status'] == 'passed'
out = ROOT / (args.action + '-command-1')
out.mkdir(mode=0o700)
result_root = ROOT / (args.action + '-1')
command = ['/usr/bin/python3', '-B', str(SOURCE / 'root_run.py'),
           'run' if args.action == 'run' else 'collect', '--inputs', str(ROOT / 'inputs-1/bound'),
           '--binding-sha256', BINDING, '--output', str(result_root)]
if args.action == 'collect':
    prior = ROOT / 'run-1/launch-receipt.json'
    record = json.loads((ROOT / 'run-command-1/receipt.json').read_bytes())
    assert record['status'] == 'passed' and record['resultSHA256'] == sha(prior)
    command += ['--launch-receipt', str(prior), '--launch-receipt-sha256', sha(prior)]
elif args.action == 'collect-failed':
    command += ['--failed-run']
receipt = dict(status='failed', action=args.action, sourceManifestSHA256=EXPECTED, bindingSHA256=BINDING)
try:
    receipt['child'] = run_owned(command, out, 'execution', 390 if args.action == 'run' else 90)
    verify()
    name = {'run': 'launch-receipt.json', 'collect': 'reference-result.json', 'collect-failed': 'failure-collection.json'}[args.action]
    receipt.update(status='passed', resultSHA256=sha(result_root / name))
finally:
    with (out / 'receipt.json').open('x') as stream:
        json.dump(receipt, stream, indent=2, sort_keys=True)
        stream.write('\n')
print(json.dumps(receipt))
