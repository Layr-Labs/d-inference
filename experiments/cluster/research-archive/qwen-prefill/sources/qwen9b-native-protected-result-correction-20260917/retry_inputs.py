"""One source correction and explicit additions to the unchanged dependency set."""
import importlib.util
import json
from pathlib import Path

BASE = Path(__file__).resolve().parent
OLD = BASE.parent / 'qwen9b-native-protected-build-draft-20260917'
spec = importlib.util.spec_from_file_location('protected_prior_build_inputs', OLD / 'build_inputs.py')
prior = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prior)
WORKSPACE, SCRATCH, sha = prior.WORKSPACE, prior.SCRATCH, prior.sha


def inputs():
    prior.frozen(BASE)
    lineage = json.loads((BASE / 'lineage.json').read_bytes())
    if sha(OLD / 'manifest.json') != lineage['baseManifestSHA256']:
        raise ValueError('Original build freeze changed')
    value, ancestor, source, overlay, exclusions = prior.inputs()
    for name, field in [('source-snapshot-1.json', 'originalSourceSnapshotSHA256'),
                        ('dependency-snapshot-1.json', 'originalDependencySnapshotSHA256')]:
        if sha(OLD / name) != lineage[field]:
            raise ValueError('Original prepared snapshot changed')
    for row in lineage['failureEvidence']:
        path = Path(row['path'])
        if path.is_symlink() or path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
            raise ValueError('Original failed evidence changed')
    row = lineage['unchangedDescriptorProducer']
    if sha(Path(row['path'])) != row['sha256']:
        raise ValueError('Protected descriptor producer changed')
    for row in json.loads((BASE / 'helper-lineage.json').read_bytes()):
        if sha(Path(row['source'])) != row.get('beforeSHA256', row.get('sha256')):
            raise ValueError('Original helper changed')
        if sha(BASE / row['path']) != row.get('afterSHA256', row.get('sha256')):
            raise ValueError('Retry helper differs')
    result = dict(value)
    result.update(originalCandidateManifestSHA256=value['candidateManifestSHA256'],
                  candidateManifestSHA256=sha(BASE / 'manifest.json'),
                  correction=lineage)
    return result, ancestor, source, overlay, exclusions


def expected(before=False):
    inputs()
    source = json.loads((OLD / 'source-snapshot-1.json').read_bytes())['members']
    by = {row['path']: row for row in source}
    overlay = json.loads((BASE / 'integration.json').read_bytes())['files']
    if len(by) != 3075 or len(overlay) != 1:
        raise ValueError('One-file correction inventory differs')
    row = overlay[0]
    if by[row['path']]['sha256'] != row['beforeSHA256']:
        raise ValueError('Prepared source preimage differs')
    corrected = BASE / 'proposed' / row['path']
    if corrected.is_symlink() or sha(corrected) != row['afterSHA256']:
        raise ValueError('Corrected source changed')
    if not before:
        by[row['path']] = dict(path=row['path'], bytes=corrected.stat().st_size,
                               sha256=row['afterSHA256'])
    deps = json.loads((OLD / 'dependency-snapshot-1.json').read_bytes())['members']
    added = json.loads((BASE / 'dependency-additions.json').read_bytes())['members']
    if len(deps) != 8755 or len(added) != 1077 or {r['path'] for r in deps} & {r['path'] for r in added}:
        raise ValueError('Explicit dependency union differs')
    combined = deps + added
    if len({r['path'] for r in combined}) != 9832:
        raise ValueError('Duplicate dependency member')
    return sorted(by.values(), key=lambda x: x['path']), sorted(combined, key=lambda x: x['path'])
