"""Exact generated source closure, checked before and after the root action."""
import hashlib,json
from pathlib import Path
BASE=Path(__file__).resolve().parent
def verify():
    for root in (BASE, BASE/'package'):
        for row in json.loads((root/'manifest.json').read_bytes())['files']:
            p=root/row['path']; raw=p.read_bytes()
            if p.is_symlink() or len(raw)!=row['bytes'] or hashlib.sha256(raw).hexdigest()!=row['sha256']:
                raise ValueError('Bound reference source differs')
