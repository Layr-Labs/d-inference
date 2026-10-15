"""Exact selected source/dependency verification for this isolated workspace."""
from pathlib import Path
import hashlib,json
BASE=Path(__file__).resolve().parent

def verify():
    counts={}
    for name,root in [('source-snapshot-1.json',BASE/'workspace'),('dependency-snapshot-1.json',BASE/'workspace/libs/darkbloom-cluster-worker/.build-native-worker/checkouts')]:
        rows=json.loads((BASE/name).read_bytes())['members']
        for row in rows:
            path=root/row['path'];raw=path.read_bytes()
            if len(raw)!=row['bytes'] or hashlib.sha256(raw).hexdigest()!=row['sha256']:
                raise RuntimeError('Build input changed: '+row['path'])
            if 'symlink' in row and str(path.readlink())!=row['symlink']:raise RuntimeError('Symlink changed')
        counts[name]=len(rows)
    return counts

if __name__=='__main__':print(json.dumps(verify(),sort_keys=True))
