"""Single-slot, root-owned canonical correction checks and exact native packaging."""
import argparse
import hashlib
import json
import os
from pathlib import Path
from check_process import run_owned

BASE = Path(__file__).resolve().parent
CORRECTION = BASE.parent / 'qwen9b-protected-canonical-description-correction-20260917'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def freeze(directory, digest=None):
    if digest is not None and sha(directory / 'manifest.json') != digest:
        raise ValueError('Manifest changed')
    for row in json.loads((directory / 'manifest.json').read_bytes())['files']:
        path = directory / row['path']
        if path.is_symlink() or path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
            raise ValueError('Source changed: ' + row['path'])

os.umask(0o077)
phases = ['controls', 'prepare', 'runtime', 'worker', 'capability', 'native', 'package']
parser = argparse.ArgumentParser(allow_abbrev=False)
parser.add_argument('phase', choices=phases)
args = parser.parse_args()
freeze(BASE)
freeze(CORRECTION, '9022cdfa9bd51a7d73439edaf822ae2ff77fa2bd062682b4f18a70ff402976e3')
if args.phase != 'controls':
    previous = BASE / ('root-' + phases[phases.index(args.phase) - 1] + '-4/receipt.json')
    prior = json.loads(previous.read_bytes())
    if prior['status'] != 'passed' or prior['manifestSHA256'] != sha(BASE / 'manifest.json'):
        raise ValueError('Previous actual phase did not pass on this source')
out = BASE / ('root-' + args.phase + '-4')
out.mkdir(mode=0o700)
receipt = dict(status='failed', phase=args.phase, manifestSHA256=sha(BASE / 'manifest.json'), steps=[])
try:
    if args.phase == 'controls':
        receipt['steps'].append(run_owned(['/usr/bin/python3', '-B', str(CORRECTION / 'check_source.py')], out, 'source', 15))
        commands = json.loads((CORRECTION / 'commands.json').read_bytes())
        (CORRECTION / 'checks-1').mkdir(mode=0o700)
        for name in ('compile', 'run'):
            receipt['steps'].append(run_owned(commands[name], out, name, commands[name + 'TimeoutSeconds']))
        expected = 'PASS 3 canonical description groups: actual policy17cc, 26-field native3 golden, independent lexical vector\n'
        if (out / 'run.stdout').read_text() != expected or (out / 'run.stderr').stat().st_size:
            raise ValueError('Actual canonical controls incomplete')
    elif args.phase == 'prepare':
        receipt['steps'].append(run_owned(['/usr/bin/python3', '-B', str(BASE / 'prepare.py')], out, 'preparation', 90))
        result = BASE / 'preparation-4/receipt.json'
        if json.loads(result.read_bytes())['status'] != 'passed':
            raise ValueError('Preparation failed')
        receipt['resultSHA256'] = sha(result)
    elif args.phase == 'package':
        receipt['steps'].append(run_owned(['/usr/bin/python3', '-B', str(BASE / 'package_native.py'),
            'runtime-4', 'worker-4', 'capability-4', 'native-4', 'runtime-bundle-4'], out, 'execution', 180))
        receipt['resultSHA256'] = sha(BASE / 'runtime-bundle-4/bundle.json')
    else:
        receipt['steps'].append(run_owned(['/usr/bin/python3', '-B', str(BASE / 'run_checks.py'), args.phase, args.phase + '-4'], out, 'execution', 1100))
        result = BASE / (args.phase + '-4/receipt.json')
        if json.loads(result.read_bytes())['status'] != 'passed':
            raise ValueError('Actual phase failed')
        receipt['resultSHA256'] = sha(result)
    freeze(BASE)
    freeze(CORRECTION, '9022cdfa9bd51a7d73439edaf822ae2ff77fa2bd062682b4f18a70ff402976e3')
    receipt['status'] = 'passed'
finally:
    with (out / 'receipt.json').open('x') as stream:
        json.dump(receipt, stream, indent=2, sort_keys=True)
        stream.write('\n')
print(json.dumps(receipt, sort_keys=True))
