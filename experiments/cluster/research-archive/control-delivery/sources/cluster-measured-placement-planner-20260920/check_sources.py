"""Small immutable source/AST check only; never invokes a compiler or fixture."""
import ast
import hashlib
import json
from pathlib import Path
import re

BASE = Path(__file__).resolve().parent

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def verify():
    manifest = json.loads((BASE / 'manifest.json').read_text())
    assert manifest['schema'] == 'measured_placement_source_v1'
    paths = []
    for row in manifest['files']:
        name = row['path']
        assert name not in paths and not Path(name).is_absolute() and '..' not in Path(name).parts
        paths.append(name)
        path = BASE / name
        assert path.is_file() and not path.is_symlink()
        assert path.stat().st_size == row['bytes'] and sha(path) == row['sha256'], name
        if path.suffix == '.py':
            ast.parse(path.read_text(), filename=name)
    contract = json.loads((BASE / 'qualification.json').read_text())
    actual = re.findall(r'^\s*\("([a-z0-9_]+)", \{', (BASE / 'Tests/PlacementChecks.swift').read_text(), re.M)
    assert actual == contract['groups'] and len(actual) == len(set(actual)) == 19
    swift = sorted(p for p in paths if p.startswith(('Sources/', 'Tests/')) and p.endswith('.swift'))
    assert swift == contract['swiftSources']
    context = json.loads((BASE / 'context.json').read_text())
    for row in context['exactHelperCopies']:
        assert sha(BASE / row['copy']) == row['sha256'] == sha(row['original'])
    assert sha(context['instructions']['path']) == context['instructions']['sha256']
    return manifest, contract

if __name__ == '__main__':
    manifest, contract = verify()
    print(json.dumps({'passed': True, 'sourceOnly': True, 'members': len(manifest['files']),
                      'swiftSources': len(contract['swiftSources']), 'stagedGroups': len(contract['groups'])}, sort_keys=True))
