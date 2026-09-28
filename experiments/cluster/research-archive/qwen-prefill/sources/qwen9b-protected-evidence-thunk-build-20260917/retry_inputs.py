"""One nonescaping thunk over the actually prepared numerical source union."""
import importlib.util
import json
from pathlib import Path

BASE = Path(__file__).resolve().parent
OLD = BASE.parent / 'qwen9b-protected-numerical-build-draft-20260917'
OLD_SHA = '684bf5f3ee466303004fa6b8bbc6ac6f40853748df2734ac6bbd97fb37e06ad4'
spec = importlib.util.spec_from_file_location('numerical_retry_inputs', OLD / 'retry_inputs.py')
previous = importlib.util.module_from_spec(spec)
spec.loader.exec_module(previous)
prior, WORKSPACE, SCRATCH, sha = previous.prior, previous.WORKSPACE, previous.SCRATCH, previous.sha

def inputs():
    prior.frozen(BASE)
    prior.frozen(OLD, OLD_SHA)
    for row in json.loads((BASE / 'parent-evidence.json').read_bytes())['files']:
        path = Path(row['path'])
        if path.is_symlink() or not path.is_file() or path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
            raise ValueError('Actual predecessor evidence changed: ' + str(path))
    value, ancestor, source, overlay, exclusions = previous.inputs()
    value = dict(value)
    value.update(previousCorrectionManifestSHA256=value['candidateManifestSHA256'],
                 candidateManifestSHA256=sha(BASE / 'manifest.json'))
    return value, ancestor, source, overlay, exclusions

def expected(before=False):
    inputs()
    source, deps = previous.expected()
    if source != json.loads((OLD / 'source-snapshot-5.json').read_bytes())['members'] or deps != json.loads((OLD / 'dependency-snapshot-5.json').read_bytes())['members']:
        raise ValueError('Prepared numerical inventory changed')
    by = {row['path']: dict(row) for row in source}
    rows = json.loads((BASE / 'integration.json').read_bytes())['files']
    if len(rows) != 1 or (len(source), len(deps)) != (3081, 9832):
        raise ValueError('Thunk scope differs')
    row = rows[0]
    if by[row['path']]['sha256'] != row['preimageSHA256']:
        raise ValueError('Numerical thunk preimage differs')
    if not before:
        by[row['path']] = dict(path=row['path'], bytes=row['bytes'], sha256=row['proposedSHA256'])
    return sorted(by.values(), key=lambda row: row['path']), deps
