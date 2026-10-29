import hashlib
import importlib.util
import json
import os
import sys
from pathlib import Path
sys.dont_write_bytecode = True
BASE = Path(__file__).resolve().parent
RUN = BASE / 'qualification-1'
PACKAGES = ('provider-swift', 'libs/darkbloom-cluster', 'libs/mlx-swift', 'libs/mlx-swift-lm')

def require(value, message):
    if not value: raise ValueError(message)
def read(path): return json.loads(Path(path).read_bytes())
def sha(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1_048_576), b''): value.update(block)
    return value.hexdigest()
def save(path, value):
    with Path(path).open('x') as stream: stream.write(json.dumps(value, indent=2, sort_keys=True) + '\n')
def pin(row):
    p = Path(row['path'])
    require(p.is_file() and not p.is_symlink() and p.stat().st_size == row['bytes'] and sha(p) == row['sha256'], 'Pinned input changed: ' + str(p))

def inputs():
    for row in read(BASE / 'manifest.json')['members']: pin(dict(row, path=str(BASE / row['path'])))
    c = read(BASE / 'context.json')
    for row in c['pins']: pin(row)
    prior = Path(c['base'])
    spec = importlib.util.spec_from_file_location('retained_master_inputs', prior / 'common.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    module.inputs() # Retain all original source/lock/SDK/application receipt gates.
    failure = read(prior / 'qualification-1/tests-2/receipt.json')
    execution = read(prior / 'qualification-1/tests-2/execution.json')
    require(failure['passed'] is False and failure['terminalInventoryMatchesCandidate'] and
            execution['exitCode'] == 1 and execution['reaped'] and execution['groupAbsent'] and not execution['timedOut'], 'Exact failed compiler attempt required')
    before = read(prior / 'qualification-1/prepare/candidate.json')
    require(read(prior / 'qualification-1/tests-2/inventory-terminal.json') == before, 'Failure source context changed')
    after = dict(before)
    for row in read(BASE / 'overlay.json'):
        require(before[row['path']] == {'sha256': row['beforeSHA256']}, 'Correction preimage differs')
        require(sha(BASE / 'proposed' / row['path']) == row['sha256'], 'Correction source differs')
        after[row['path']] = {'sha256': row['sha256']}
    require(after == read(BASE / 'candidate-after.json') and sha(BASE / 'candidate-after.json') == c['candidateSHA256'], 'Only two exact corrected source files allowed')
    return c, Path(c['workspace']), before, after

def helper(c):
    root = Path(c['base']) / 'qualification-1/helper'
    receipt, value = read(root / 'receipt.json'), read(root / 'checks.json')
    require(receipt['passed'] and receipt['candidateSHA256'] == c['priorCandidateSHA256'] and receipt['terminalInventoryMatchesCandidate'] and
            value['passed'] and len(value['steps']) == 6 and sha(root / 'checks.json') == c['helperChecksSHA256'], 'Actual six-step helper required')
    for item in value['steps']:
        record = read(root / (item['name'] + '.json'))
        require(record == item['execution'] and sha(root / (item['name'] + '.json')) == item['executionSHA256'] and record['exitCode'] == 0 and record['reaped'] and record['groupAbsent'] and not record['timedOut'], 'Helper compilation identity changed')
    for item in value['artifacts']:
        require(Path(item['path']).parent == root, 'Unexpected helper artifact path'); pin(item)
    # Both successor files are outside all five helper module/fixture sources.
    require(all(row['path'].startswith('provider-swift/') for row in read(BASE / 'overlay.json')), 'Helper-source delta requires a new helper')
    return root

def clean_environment():
    names = ('PATH','HOME','USER','LOGNAME','LANG','LC_ALL','DEVELOPER_DIR','SDKROOT')
    keep = {k: os.environ[k] for k in names if k in os.environ}
    os.environ.clear(); os.environ.update(keep)
    os.environ['TMPDIR'] = '/private/tmp'; os.environ['PYTHONDONTWRITEBYTECODE'] = '1'
