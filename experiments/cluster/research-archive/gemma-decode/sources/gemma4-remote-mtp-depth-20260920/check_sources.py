import ast
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent

def read(row, root=ROOT):
    path = Path(row['path'])
    if not path.is_absolute():
        assert '..' not in path.parts
        path = root/path
    assert path.is_file() and not path.is_symlink()
    data = path.read_bytes()
    assert len(data) == row['bytes'] and hashlib.sha256(data).hexdigest() == row['sha256'], path
    return data

def main():
    for row in json.loads((ROOT/'source-inputs.json').read_text())['members']:
        read(row)
        if row['path'].endswith('.py'):
            ast.parse(read(row), row['path'])
    spec = json.loads((ROOT/'composition.json').read_text())
    base = json.loads(read(spec['baseSources']))
    files = {row['path']: row for row in base['files']}
    assert len(files) == len(base['files']) == 116 and len(spec['files']) == 3
    for row in spec['files']:
        after = read(dict(path=row['source'], bytes=row['bytes'], sha256=row['sha256'])).decode()
        if row['before'] is None:
            assert row['path'] not in files
        else:
            assert files[row['path']] == row['before']
            before = read(dict(row['before'], path='preimages/'+Path(row['path']).name)).decode()
            value = before
            for op in row['operations']:
                assert value.count(op['before']) == op['count']
                value = value.replace(op['before'], op['after'])
            assert value == after
            for op in reversed(row['operations']):
                assert value.count(op['after']) == op['count']
                value = value.replace(op['after'], op['before'])
            assert value == before
        files[row['path']] = dict(path=row['path'], bytes=row['bytes'], sha256=row['sha256'])
    assert [files[key] for key in sorted(files)] == json.loads((ROOT/'expected-sources.json').read_text())['files']
    for row in json.loads((ROOT/'protocol-sources.json').read_text())['sources']:
        read(row)
    predecessor = read(json.loads((ROOT/'test-predecessor.json').read_text())).decode()
    current = (ROOT/'Tests/RemoteDepthCheck.swift').read_text()
    pattern = r'try group\("([^"]+)"'
    old = re.findall(pattern, predecessor)
    new = re.findall(pattern, current)
    assert len(old) == 18 and new[:18] == old and len(new) == 26 and len(set(new)) == 26
    assert new == json.loads((ROOT/'Tests/expected-groups.json').read_text())['groups']
    # Every original test body remains literal, before the eight added groups.
    start = predecessor.index('        try group(')
    end = predecessor.index('        let output:')
    assert predecessor[start:end] in current
    print(json.dumps(dict(status='source-checked', overlays=2, additions=1,
        sourceMembers=117, stagedFoundationGroups=26, compilerExecuted=False, nativeExecuted=False)))

if __name__ == '__main__':
    main()
