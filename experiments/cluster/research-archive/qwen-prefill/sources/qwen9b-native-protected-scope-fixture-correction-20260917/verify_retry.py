"""Exact source/dependency union; no accepting a newly observed current tree."""
import json
import subprocess
from retry_inputs import BASE, OLD, WORKSPACE, SCRATCH, prior, expected


def verify(before=False, require_snapshots=True):
    source, deps = expected(before)
    counts = {}
    for filename, root, rows in [
        ('source-snapshot-3.json', WORKSPACE, source),
        ('dependency-snapshot-3.json', SCRATCH / 'checkouts', deps),
    ]:
        if prior.entries(root) != rows:
            raise ValueError('Exact retry inventory differs: ' + filename)
        if require_snapshots and json.loads((BASE / filename).read_bytes())['members'] != rows:
            raise ValueError('Retry snapshot differs from its explicit source union')
        counts[filename] = len(rows)
    audit = json.loads((OLD / 'dependency-audit.json').read_bytes())
    for row in audit['allCheckoutPointers']:
        directory = SCRATCH / 'checkouts' / row['directory']
        head = subprocess.check_output(['git', '--no-optional-locks', '-C', str(directory),
            'rev-parse', 'HEAD'], text=True, timeout=10).strip()
        if head != row['pin']['state']['revision'] or head != row['head']:
            raise ValueError('Explicit added checkout revision changed')
    return counts


if __name__ == '__main__':
    print(json.dumps(verify(), sort_keys=True))
