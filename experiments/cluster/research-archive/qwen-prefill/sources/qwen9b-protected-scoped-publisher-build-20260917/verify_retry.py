"""Keep the exact full source/dependency inventories and checkout revisions."""
import json
import subprocess
from retry_inputs import BASE, OLD, WORKSPACE, SCRATCH, prior, expected, sha

def verify(before=False, require_snapshots=True):
    source, deps = expected(before)
    counts = {}
    for name, root, rows in [('source-snapshot-7.json', WORKSPACE, source),
                             ('dependency-snapshot-7.json', SCRATCH / 'checkouts', deps)]:
        if prior.entries(root) != rows:
            raise ValueError('Exact source inventory differs: ' + name)
        if require_snapshots and json.loads((BASE / name).read_bytes())['members'] != rows:
            raise ValueError('Explicit snapshot differs')
        counts[name] = len(rows)
    audit = json.loads((BASE.parent / 'qwen9b-native-protected-result-correction-20260917/dependency-audit.json').read_bytes())
    for row in audit['allCheckoutPointers']:
        directory = SCRATCH / 'checkouts' / row['directory']
        head = subprocess.check_output(['git', '--no-optional-locks', '-C', str(directory), 'rev-parse', 'HEAD'], text=True, timeout=10).strip()
        if head != row['pin']['state']['revision'] or head != row['head']:
            raise ValueError('Dependency revision changed')
    preserved = BASE.parent / 'qwen9b-protected-numerical-build-draft-20260917/preparation-5/darkbloom-cluster-worker.canonical4'
    if preserved.is_symlink() or sha(preserved) != 'dd277746f02ef87e00a517b63932a111ea986b1a4c361718ba8cf05012d9dd70':
        raise ValueError('Preserved canonical native changed')
    if not before:
        row = json.loads((BASE / 'integration.json').read_bytes())['files'][0]
        if sha(BASE / 'preparation-7/original.swift') != row['preimageSHA256']:
            raise ValueError('Preserved numerical source changed')
    return counts
