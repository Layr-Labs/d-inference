"""Preserve the qualified source union; replace only the failing macro expression."""
import hashlib
import importlib.util
import json
from pathlib import Path

BASE = Path(__file__).resolve().parent
OLD = BASE.parent / 'qwen9b-native-protected-result-correction-20260917'
lineage = json.loads((BASE / 'lineage.json').read_bytes())
if hashlib.sha256((OLD / 'retry_inputs.py').read_bytes()).hexdigest() != lineage['previousInputsSHA256']:
    raise ValueError('Previous guarded input helper changed')
spec = importlib.util.spec_from_file_location('protected_result_retry_inputs', OLD / 'retry_inputs.py')
previous = importlib.util.module_from_spec(spec)
spec.loader.exec_module(previous)
prior = previous.prior
WORKSPACE, SCRATCH, sha = previous.WORKSPACE, previous.SCRATCH, previous.sha


def inputs():
    prior.frozen(BASE)
    lineage = json.loads((BASE / 'lineage.json').read_bytes())
    for name, field in [('manifest.json', 'previousManifestSHA256'),
                        ('source-snapshot-2.json', 'sourceSnapshot2SHA256'),
                        ('dependency-snapshot-2.json', 'dependencySnapshot2SHA256'),
                        ('dependency-audit.json', 'dependencyAuditSHA256')]:
        if sha(OLD / name) != lineage[field]:
            raise ValueError('Previous runtime correction/snapshot changed')
    value, ancestor, source, overlay, exclusions = previous.inputs()
    for row in lineage['failureEvidence']:
        path = Path(row['path'])
        if path.is_symlink() or path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
            raise ValueError('Preserved second failed build evidence changed')
    for row in json.loads((BASE / 'helper-lineage.json').read_bytes()):
        if sha(Path(row['source'])) != row.get('beforeSHA256', row.get('sha256')):
            raise ValueError('Previous helper changed')
        if sha(BASE / row['path']) != row.get('afterSHA256', row.get('sha256')):
            raise ValueError('Current retry helper changed')
    result = dict(value)
    result.update(previousCorrectionManifestSHA256=value['candidateManifestSHA256'],
                  previousCorrection=value['correction'], correction=lineage,
                  candidateManifestSHA256=sha(BASE / 'manifest.json'))
    return result, ancestor, source, overlay, exclusions


def expected(before=False):
    inputs()
    source, deps = previous.expected()
    if source != json.loads((OLD / 'source-snapshot-2.json').read_bytes())['members']:
        raise ValueError('Previous source snapshot differs from its reviewed union')
    if deps != json.loads((OLD / 'dependency-snapshot-2.json').read_bytes())['members']:
        raise ValueError('Previous dependency snapshot differs from its explicit union')
    by = {row['path']: row for row in source}
    overlay = json.loads((BASE / 'integration.json').read_bytes())['files']
    if len(by) != 3075 or len(deps) != 9832 or len(overlay) != 1:
        raise ValueError('Fixture-only retry inventory differs')
    row = overlay[0]
    if by[row['path']]['sha256'] != row['beforeSHA256']:
        raise ValueError('Fixture preimage differs')
    corrected = BASE / 'proposed' / row['path']
    if corrected.is_symlink() or sha(corrected) != row['afterSHA256']:
        raise ValueError('Corrected fixture changed')
    if not before:
        by[row['path']] = dict(path=row['path'], bytes=corrected.stat().st_size,
                              sha256=row['afterSHA256'])
    return sorted(by.values(), key=lambda x: x['path']), deps
