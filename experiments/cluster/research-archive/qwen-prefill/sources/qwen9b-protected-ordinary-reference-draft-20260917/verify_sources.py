"""Verify only this small frozen invocation package and pinned source metadata."""
import ast
import hashlib
import json
from pathlib import Path

BASE = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify():
    python_sources = set()
    for directory in (BASE, BASE / 'package'):
        for row in json.loads((directory / 'manifest.json').read_bytes())['files']:
            path = directory / row['path']
            if path.is_symlink() or path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
                raise ValueError('Frozen invocation source changed')
            if path.suffix == '.py':
                python_sources.add(path)
    for row in json.loads((BASE / 'source-authorities.json').read_bytes())['files']:
        if sha(Path(row['path'])) != row['sha256']:
            raise ValueError('Pinned native/source authority changed')
    for row in json.loads((BASE / 'helper-lineage.json').read_bytes()):
        if sha(Path(row['source'])) != row['sha256']:
            raise ValueError('Qualified helper predecessor changed')
        if row['byteExact'] and sha(BASE / row['path']) != row['sha256']:
            raise ValueError('Exact helper copy changed')
    for p in python_sources:
        ast.parse(p.read_text(), filename=str(p))
    return dict(sourceOnly=True, compilerExecuted=False, modelExecuted=False, remoteExecuted=False)


if __name__ == '__main__':
    print(json.dumps(verify(), sort_keys=True))
