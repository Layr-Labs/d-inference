"""Add the omitted real ProbeError source to the CPU-only fixture closure."""
import hashlib
import json
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent
DRAFT = ROOT.parent / 'resident-generation-phase-native-draft-20260916'
sys.path.insert(0, str(DRAFT / 'Build'))
from build_inputs import authority, OLD, sha
from owned_process import invoke_controller

os.umask(0o077)
sources, _ = authority()
original = DRAFT / 'Build/cpu-1'
failed = json.loads((original / 'receipt.json').read_text())
assert not failed['passed'] and len(failed['steps']) == 3
assert all(step['exitCode'] == 0 and step['reaped'] and step['groupAbsent'] for step in failed['steps'][:2])
assert failed['steps'][2]['exitCode'] == 1 and failed['steps'][2]['reaped'] and failed['steps'][2]['groupAbsent']
assert json.loads((original / 'phases-run.stdout').read_text())['count'] == 11
relative = 'libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/ClusterRuntimeError.swift'
missing = OLD / 'workspace' / relative
expected = next(row for row in sources if row['path'] == relative)
assert sha(missing) == expected['sha256'] and missing.stat().st_size == expected['bytes']
out = ROOT / 'encoding-retry-1'
out.mkdir(mode=0o700)
old_argv = failed['steps'][2]['argv']
assert old_argv[-2] == '-o' and str(missing) not in old_argv
argv = old_argv[:-2] + [str(missing), '-o', str(out / 'encoding')]
receipt = {'passed': False, 'steps': [], 'originalCPUReceiptSHA256': sha(original / 'receipt.json'),
           'original11GroupsPassed': True, 'fixtureDependency': expected,
           'runtimeSourceChanged': False, 'modelOrRemoteExecuted': False}
try:
    for name, command, timeout in [
        ('encoding-compile', argv, 90),
        ('encoding-run', [str(out / 'encoding')], 30),
        ('phase-schema', ['/usr/bin/python3', '-B', str(DRAFT / 'Tests/test_phase_schema.py')], 30),
    ]:
        step = {'name': name, 'argv': command}
        receipt['steps'].append(step)
        with (out / (name + '.stdout')).open('xb') as stdout, (out / (name + '.stderr')).open('xb') as stderr:
            invoke_controller(command, stdout, stderr, step, timeout=timeout)
        if step.get('exitCode') != 0 or not step.get('reaped') or not step.get('groupAbsent'):
            raise RuntimeError('Encoding fixture retry failed: ' + name)
    assert json.loads((out / 'encoding-run.stdout').read_text())['count'] == 5
    assert 'Ran 4 tests' in (out / 'phase-schema.stderr').read_text()
    authority()
    assert sha(missing) == expected['sha256']
    assert sha(original / 'receipt.json') == receipt['originalCPUReceiptSHA256']
    receipt.update(passed=True, foundationGroups=16, pythonMethods=4, sourcePinsUnchanged=True)
finally:
    with (out / 'receipt.json').open('x') as f:
        json.dump(receipt, f, indent=2)
        f.write('\n')
print(json.dumps({'passed': True, 'foundationGroups': 16, 'pythonMethods': 4}))
