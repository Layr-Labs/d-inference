"""Check the frozen, small source/configuration closure before post-run tools."""
from pathlib import Path
import hashlib
import json

BASE = Path(__file__).resolve().parent


def verify_package():
    for name, row in json.loads((BASE / 'manifest.json').read_bytes())['files'].items():
        raw = (BASE / name).read_bytes()
        if len(raw) != row['bytes'] or hashlib.sha256(raw).hexdigest() != row['sha256']:
            raise ValueError('Frozen timing package changed: ' + name)
