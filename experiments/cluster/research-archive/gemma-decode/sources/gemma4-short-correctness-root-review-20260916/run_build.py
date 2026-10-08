"""Root-owned exact preparation/build commands; never runs a model mode."""
import hashlib
import json
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent
DRAFT = ROOT.parent / 'gemma4-short-correctness-draft-20260916'
assert hashlib.sha256((DRAFT / 'manifest.json').read_bytes()).hexdigest() == '3803a23ef63b93ae7fbfdcf6a52b7818e4c8e5a14c36c90b9adb82f4a7afcdf2'
sys.path.insert(0, str(DRAFT / 'build'))
from build_inputs import inputs
from owned_process import invoke_controller

phase, = sys.argv[1:]
assert phase in ('prepare', 'build')
inputs()
commands = json.loads((DRAFT / 'build/commands.json').read_text())['sequential']
selected = list(zip(commands[:3], (180, 180, 90))) if phase == 'prepare' else [(commands[3], 1000)]
os.umask(0o077)
os.chdir(DRAFT / 'build')
for command, timeout in selected:
    name = Path(command['argv'][2]).stem
    record = {'phase': name, 'argv': command['argv']}
    with (ROOT / (name + '-outer-1.json')).open('x') as result:
        try:
            with (ROOT / (name + '-outer-1.stdout')).open('xb') as stdout, (ROOT / (name + '-outer-1.stderr')).open('xb') as stderr:
                invoke_controller(command['argv'], stdout, stderr, record, timeout=timeout)
        finally:
            json.dump(record, result, indent=2)
            result.write('\n')
    if record.get('exitCode') != 0 or not record.get('reaped') or not record.get('groupAbsent'):
        raise RuntimeError('Gemma build phase failed: ' + name)
    print(json.dumps(record, sort_keys=True), flush=True)
