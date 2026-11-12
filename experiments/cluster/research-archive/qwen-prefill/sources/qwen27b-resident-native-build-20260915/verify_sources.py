"""Verify staged source/dependency bytes without compilation or model access."""
from pathlib import Path
import hashlib
import json
import os

ROOT = Path(__file__).resolve().parent

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def verify(root, rows):
    for row in rows:
        path = root / row['path']
        if 'symlink' in row:
            assert path.is_symlink() and os.readlink(path) == row['symlink'], str(path)
        else:
            assert path.is_file() and path.stat().st_size == row['bytes'] and sha(path) == row['sha256'], str(path)

if __name__ == '__main__':
    source = json.loads((ROOT / 'source-snapshot.json').read_text())
    verify(ROOT / 'workspace', source['members'])
    dependencies = json.loads((ROOT / 'dependency-source-snapshot.json').read_text())
    for cache in dependencies['privateCaches']:
        verify(Path(cache) / 'checkouts', dependencies['members'])
    print(json.dumps({'sourceMembersVerified': len(source['members']),
        'dependencyMembersVerifiedPerCache': len(dependencies['members']),
        'privateCaches': len(dependencies['privateCaches']), 'compilerExecuted': False}))
