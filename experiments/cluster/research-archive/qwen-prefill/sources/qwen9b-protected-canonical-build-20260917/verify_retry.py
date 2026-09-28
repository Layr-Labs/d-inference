"""Verify the complete original union plus exactly two canonical producer files."""
import json
import subprocess
from retry_inputs import BASE, OLD, WORKSPACE, SCRATCH, prior, expected, sha

def verify(before=False, require_snapshots=True):
    source, deps = expected(before)
    counts = {}
    for name, root, rows in [('source-snapshot-4.json', WORKSPACE, source),
                              ('dependency-snapshot-4.json', SCRATCH / 'checkouts', deps)]:
        if prior.entries(root) != rows:
            raise ValueError('Exact source inventory differs: ' + name)
        if require_snapshots and json.loads((BASE / name).read_bytes())['members'] != rows:
            raise ValueError('Snapshot differs from explicit reviewed source union')
        counts[name] = len(rows)
    audit = json.loads((OLD.parent / 'qwen9b-native-protected-result-correction-20260917/dependency-audit.json').read_bytes())
    for row in audit['allCheckoutPointers']:
        directory = SCRATCH / 'checkouts' / row['directory']
        head = subprocess.check_output(['git', '--no-optional-locks', '-C', str(directory), 'rev-parse', 'HEAD'], text=True, timeout=10).strip()
        if head != row['pin']['state']['revision'] or head != row['head']:
            raise ValueError('Dependency revision changed')
    if not before:
        preserved = BASE / 'preparation-4/darkbloom-cluster-worker.native3'
        if preserved.is_symlink() or sha(preserved) != 'a0ecbb951d1bc3116758d8ef2c34eb4e2ed179dedcbcd54985869d467af14bac':
            raise ValueError('Preserved actual failed-metadata native changed')
    return counts
