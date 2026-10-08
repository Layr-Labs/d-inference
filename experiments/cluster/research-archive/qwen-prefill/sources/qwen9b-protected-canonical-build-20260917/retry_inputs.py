"""Compose the canonical producer correction over the exact native3 source union."""
import importlib.util
import json
from pathlib import Path

BASE = Path(__file__).resolve().parent
OLD = BASE.parent / 'qwen9b-native-protected-scope-fixture-correction-20260917'
CORRECTION = BASE.parent / 'qwen9b-protected-canonical-description-correction-20260917'
spec = importlib.util.spec_from_file_location('protected_scope_retry_inputs', OLD / 'retry_inputs.py')
previous = importlib.util.module_from_spec(spec)
spec.loader.exec_module(previous)
prior = previous.prior
WORKSPACE, SCRATCH, sha = previous.WORKSPACE, previous.SCRATCH, previous.sha

def inputs():
    prior.frozen(BASE)
    prior.frozen(OLD, 'b05141ec68aa28442cf931f2d853292c4d23a4dfb96f51aea5e4685311710d90')
    prior.frozen(CORRECTION, '9022cdfa9bd51a7d73439edaf822ae2ff77fa2bd062682b4f18a70ff402976e3')
    for row in json.loads((BASE / 'lineage.json').read_bytes())['evidence']:
        path = Path(row['path'])
        if path.is_symlink() or path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
            raise ValueError('Prior evidence changed')
    value, ancestor, source, overlay, exclusions = previous.inputs()
    result = dict(value)
    result.update(previousCorrectionManifestSHA256=value['candidateManifestSHA256'],
                  candidateManifestSHA256=sha(BASE / 'manifest.json'),
                  canonicalProducerCorrectionSHA256=sha(CORRECTION / 'manifest.json'))
    return result, ancestor, source, overlay, exclusions

def expected(before=False):
    inputs()
    source, deps = previous.expected()
    if source != json.loads((OLD / 'source-snapshot-3.json').read_bytes())['members']:
        raise ValueError('Previous source snapshot is not its original reviewed union')
    if deps != json.loads((OLD / 'dependency-snapshot-3.json').read_bytes())['members']:
        raise ValueError('Previous dependency snapshot differs')
    by = {row['path']: row for row in source}
    rows = json.loads((CORRECTION / 'integration.json').read_bytes())['files']
    if (len(by), len(deps), len(rows)) != (3075, 9832, 2):
        raise ValueError('Unexpected source scope')
    for row in rows:
        if by.get(row['path'], {}).get('sha256') != row['preimageSHA256']:
            raise ValueError('Exact producer preimage differs')
        path = Path(row['sourcePath'])
        if path.is_symlink() or sha(path) != row['proposedSHA256']:
            raise ValueError('Corrected producer changed')
        if not before:
            by[row['path']] = dict(path=row['path'], bytes=path.stat().st_size, sha256=row['proposedSHA256'])
    return sorted(by.values(), key=lambda row: row['path']), deps
