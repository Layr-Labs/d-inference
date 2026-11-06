"""Exact canonical source union plus the frozen14 native numerical files."""
import importlib.util
import json
from pathlib import Path

BASE = Path(__file__).resolve().parent
OLD = BASE.parent / 'qwen9b-protected-canonical-build-20260917'
NUMERICAL = BASE.parent / 'qwen9b-protected-numerical-evidence-draft-20260917'
OLD_SHA = '23be7a1fa8ac6ca09a2aa37af289cf099304babd0b48627a1f2e44ce40d1ad8e'
NUMERICAL_SHA = '948ef71c633789e321bcf4fc1e61a58bf96edd8578ee357fda07329c4149fb4d'
spec = importlib.util.spec_from_file_location('canonical_retry_inputs', OLD / 'retry_inputs.py')
previous = importlib.util.module_from_spec(spec)
spec.loader.exec_module(previous)
prior = previous.prior
WORKSPACE, SCRATCH, sha = previous.WORKSPACE, previous.SCRATCH, previous.sha

def inputs():
    prior.frozen(BASE)
    prior.frozen(OLD, OLD_SHA)
    prior.frozen(NUMERICAL, NUMERICAL_SHA)
    value, ancestor, source, overlay, exclusions = previous.inputs()
    result = dict(value)
    result.update(previousCorrectionManifestSHA256=value['candidateManifestSHA256'],
                  candidateManifestSHA256=sha(BASE / 'manifest.json'), numericalSourceManifestSHA256=NUMERICAL_SHA)
    return result, ancestor, source, overlay, exclusions

def expected(before=False):
    inputs()
    source, deps = previous.expected()
    if source != json.loads((OLD / 'source-snapshot-4.json').read_bytes())['members'] or deps != json.loads((OLD / 'dependency-snapshot-4.json').read_bytes())['members']:
        raise ValueError('Canonical source/dependency snapshot differs from original reviewed union')
    by = {row['path']: row for row in source}
    selected = json.loads((BASE / 'integration.json').read_bytes())['files']
    original = json.loads((NUMERICAL / 'integration.json').read_bytes())['files']
    native = [dict(r) for r in original if not r['path'].startswith('provider-swift/') and '/DarkbloomClusterRemote/' not in r['path']]
    sink = 'libs/darkbloom-cluster-worker/Sources/DarkbloomClusterWorker/ResidentEvidenceSink.swift'
    sink_row = next(r for r in native if r['path'] == sink)
    preserved = BASE / 'originals/ResidentEvidenceSink.swift'
    if sink_row['preimageSHA256'] is not None or sha(preserved) != 'cc34788d3fbd8409ff0ff086d6cb7d2dfb2a2ee860dfccb8a1fba5496aff6bfe':
        raise ValueError('Explicit existing-sink preimage differs')
    sink_row.update(preimageSHA256=sha(preserved), preimageSourcePath=str(preserved))
    if selected != native or (len(by), len(deps), len(selected)) != (3076, 9832, 14):
        raise ValueError('Numerical native scope differs')
    for row in selected:
        if by.get(row['path'], {}).get('sha256') != row['preimageSHA256']:
            raise ValueError('Canonical native preimage differs: ' + row['path'])
        path = Path(row['sourcePath'])
        if path.is_symlink() or path.stat().st_size != row['bytes'] or sha(path) != row['proposedSHA256']:
            raise ValueError('Numerical source changed')
        if not before: by[row['path']] = dict(path=row['path'], bytes=row['bytes'], sha256=row['proposedSHA256'])
    if len(by) != (3076 if before else 3081): raise ValueError('Numerical source count differs')
    return sorted(by.values(), key=lambda row: row['path']), deps
