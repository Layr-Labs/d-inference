"""Small source/evidence checks only; workspace preparation remains frozen."""
import ast
import hashlib
import json
from pathlib import Path

BASE = Path(__file__).resolve().parent
FROZEN = BASE.parent / 'cluster-native-shared-hardware-go-qualification-draft-20260917'
PIN = '332bb5d6dcb766ea59859b6564e6eba2129f0885fcdce6cd94283d4cb8eb1c51'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_source():
    if sha(FROZEN / 'manifest.json') != PIN:
        raise ValueError('Original frozen wrapper differs')
    manifest = BASE / 'manifest.json'
    if manifest.exists():
        for row in json.loads(manifest.read_bytes())['files']:
            p = BASE / row['path']
            if p.is_symlink() or not p.is_file() or p.stat().st_size != row['bytes'] or sha(p) != row['sha256']:
                raise ValueError('Runner correction differs: ' + str(p))
    for row in json.loads((BASE / 'parent-pins.json').read_bytes()):
        p = Path(row['path'])
        if p.is_symlink() or not p.is_file() or p.stat().st_size != row['bytes'] or sha(p) != row['sha256']:
            raise ValueError('Retained failed evidence/source differs: ' + str(p))
    for path in BASE.glob('*.py'):
        ast.parse(path.read_text(), filename=str(path))


if __name__ == '__main__':
    verify_source()
    print('PASS runner-only source/evidence pins and AST; no workspace, compiler or test execution')
