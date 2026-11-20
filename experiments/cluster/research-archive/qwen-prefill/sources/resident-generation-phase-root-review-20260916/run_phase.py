"""Run one reviewed command with the inherited owned-child bound and fresh logs."""
import hashlib
import json
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent
DRAFT = ROOT.parent / 'resident-generation-phase-native-draft-20260916'
assert hashlib.sha256((DRAFT / 'commands.json').read_bytes()).hexdigest() == 'b07805a0cc0c792d769946521a052b55df817bbbf813962212049590da6505a0'
assert hashlib.sha256((DRAFT / 'manifest.json').read_bytes()).hexdigest() == '7f8f67a9c06ca9185da981abee26afea18b6b3e1f88b8723b38e40d6391146c0'
sys.path.insert(0, str(DRAFT / 'Build'))
from build_inputs import authority
from owned_process import invoke_controller

phase, = sys.argv[1:]
command = next(row for row in json.loads((DRAFT / 'commands.json').read_text())['sequence'] if row['name'] == phase)
authority()
os.umask(0o077)
os.chdir(command['cwd'])
receipt = {'phase': phase, 'argv': command['argv']}
with (ROOT / (phase + '-outer-1.json')).open('x') as result:
    try:
        with Path(command['stdoutFile']).open('xb') as stdout, Path(command['stderrFile']).open('xb') as stderr:
            invoke_controller(command['argv'], stdout, stderr, receipt, timeout=command['outerTimeoutSeconds'])
    finally:
        json.dump(receipt, result, indent=2)
        result.write('\n')
if receipt.get('exitCode') != 0 or not receipt.get('reaped') or not receipt.get('groupAbsent'):
    raise RuntimeError('Reviewed phase failed or left an owned group: ' + phase)
print(json.dumps(receipt, sort_keys=True))
