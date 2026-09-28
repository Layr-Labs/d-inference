import argparse
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT.parent / 'qwen9b-protected-reference-install-draft-20260917'
REFERENCE = ROOT.parent / 'qwen9b-protected-ordinary-reference-draft-20260917'
EXPECTED = 'c9963c5455a9945974ab51618d68d4da98e81270c2c664d50cf0132f1e53ab3d'
sys.path.insert(0, str(REFERENCE))
from check_process import run_owned

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def verify():
    assert sha(SOURCE / 'manifest.json') == EXPECTED
    for row in json.loads((SOURCE / 'manifest.json').read_bytes())['files']:
        path = SOURCE / row['path']
        assert not path.is_symlink() and path.stat().st_size == row['bytes'] and sha(path) == row['sha256']

parser = argparse.ArgumentParser(allow_abbrev=False)
parser.add_argument('action', choices=['install', 'preflight'])
args = parser.parse_args()
verify()
if args.action == 'preflight':
    previous = json.loads((ROOT / 'install-command-1/receipt.json').read_bytes())
    assert previous['status'] == 'passed' and previous['manifestSHA256'] == EXPECTED
    assert sha(ROOT / 'install-1/receipt.json') == previous['resultSHA256']
out = ROOT / (args.action + '-command-1')
out.mkdir(mode=0o700)
row, = [item for item in json.loads((SOURCE / 'commands.json').read_bytes())['sequential'] if item['action'] == args.action]
command = ['/usr/bin/python3'] + row['argv'][1:]
receipt = dict(status='failed', action=args.action, manifestSHA256=EXPECTED)
try:
    receipt['child'] = run_owned(command, out, 'execution', 115)
    verify()
    result = ROOT / (args.action + '-1/receipt.json')
    assert json.loads(result.read_bytes())['status'] == 'passed'
    receipt.update(status='passed', resultSHA256=sha(result))
finally:
    with (out / 'receipt.json').open('x') as stream:
        json.dump(receipt, stream, indent=2, sort_keys=True)
        stream.write('\n')
print(json.dumps(receipt))
