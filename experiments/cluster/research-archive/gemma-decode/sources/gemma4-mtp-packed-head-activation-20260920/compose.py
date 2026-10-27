#!/usr/bin/env python3
"""Exact five-file successor. No compiler, native process or remote operation."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent

def digest(data):
    return hashlib.sha256(data).hexdigest()

def pin(path):
    data = path.read_bytes()
    return dict(path=str(path), bytes=len(data), sha256=digest(data))

def read(row, root=None):
    path = Path(row['path'])
    if not path.is_absolute():
        assert root is not None and '..' not in path.parts
        path = root / path
    assert path.is_file() and not path.is_symlink(), str(path)
    data = path.read_bytes()
    assert len(data) == row['bytes'] and digest(data) == row['sha256'], str(path)
    return data

def check():
    for row in json.loads((ROOT/'source-inputs.json').read_text())['members']:
        read(row, ROOT)
    spec = json.loads((ROOT/'composition.json').read_text())
    base = json.loads(read(spec['baseSources']))
    build = json.loads(read(spec['baseBuild']))
    assert build['status'] == 'passed' and build['exitCode'] == 0
    assert build['compilerReaped'] is True and build['groupAbsent'] is True
    assert build['sourcesSHA256'] == spec['baseSources']['sha256']
    prerequisite = json.loads(read(json.loads((ROOT/'qualification.json').read_text())['comparison']))
    assert prerequisite['status'] == 'passed' and prerequisite['physicalExecutionPassed'] is True
    assert prerequisite['originalProcessRetired'] is True and prerequisite['sameEmptyLeaseInode'] is True
    assert prerequisite['sourceSHA256'] == spec['baseSources']['sha256']
    assert prerequisite['nativeSHA256'] == build['nativeSHA256']
    assert prerequisite['projectionPolicy'] == 'gemma4_verification_packed_m1_dense_packed_head_v1'
    numerical = prerequisite['numerical']
    assert numerical['exactNumericsPassed'] is True
    assert (numerical['fullRowsRead'], numerical['nativeStateComponentsRead']) == (24, 360)
    assert numerical['toleranceApplied'] is False
    files = {row['path']: row for row in base['files']}
    assert len(files) == len(base['files']) == 116 and len(spec['files']) == 5
    for row in spec['files']:
        assert files[row['path']] == row['before']
        before = read(dict(row['before'], path='preimages/'+Path(row['path']).name), ROOT).decode()
        after = read(dict(path=row['source'], bytes=row['bytes'], sha256=row['sha256']), ROOT).decode()
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
    expected = json.loads((ROOT/'expected-sources.json').read_text())['files']
    assert [files[key] for key in sorted(files)] == expected
    return spec, base, expected

def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    spec, base, expected = check()
    if not args.apply:
        assert args.output is None
        print(json.dumps(dict(status='source-checked', overlays=5, sourceMembers=116,
            workspaceMutated=False, compilerExecuted=False, nativeExecuted=False)))
        return
    assert args.output and args.output.is_absolute() and not args.output.exists()
    workspace = Path(spec['workspace'])
    assert workspace.resolve() == workspace and base['workspace'] == str(workspace)
    for row in base['files']:
        read(row, workspace)
    args.output.mkdir(parents=True)
    for row in spec['files']:
        for part, data in [('before', read(row['before'], workspace)),
                ('after', read(dict(path=row['source'], bytes=row['bytes'], sha256=row['sha256']), ROOT))]:
            path = args.output / part / row['path']
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open('xb') as stream:
                stream.write(data)
    for row in spec['files']:
        read(row['before'], workspace)
        (workspace/row['path']).write_bytes((ROOT/row['source']).read_bytes())
    for row in expected:
        read(row, workspace)
    result = dict(base)
    result.update(files=expected, workspaceMutated=True, compilerExecuted=False,
        packedHeadActivationPredecessor=spec['baseSources'],
        packedHeadActivationManifestSHA256=pin(ROOT/'source-inputs.json')['sha256'],
        packedHeadActivationCompositionSHA256=pin(ROOT/'composition.json')['sha256'],
        packedHeadQualification=json.loads((ROOT/'qualification.json').read_text())['comparison'])
    path = args.output/'sources.json'
    with path.open('x') as stream:
        json.dump(result, stream, indent=2)
        stream.write('\n')
    print(json.dumps(pin(path)))

if __name__ == '__main__':
    main()
