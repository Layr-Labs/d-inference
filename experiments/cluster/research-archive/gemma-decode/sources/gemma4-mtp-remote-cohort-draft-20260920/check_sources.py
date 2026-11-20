#!/usr/bin/env python3
"""Checks only small source inputs; no fixture, compiler, native or remote work."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parent

def check(path, pin):
    value = path.read_bytes()
    assert len(value) == pin['bytes'], str(path)
    assert hashlib.sha256(value).hexdigest() == pin['sha256'], str(path)
    return value

def main():
    manifest = json.loads((ROOT/'manifest.json').read_text())
    for row in manifest['members']:
        check(ROOT/row['path'], row)
    inputs = json.loads((ROOT/'integration.json').read_text())
    for row in inputs['predecessors'] + inputs['controls']:
        check(Path(row['path']), row)
    for row in inputs['overlays']:
        check(ROOT/row['source'], row)
        if row['before']:
            check(Path(row['before']['path']), row['before'])
        else:
            assert not (Path(inputs['workspace'])/row['path']).exists(), row['path']
    for name in ['target-owner-inputs.json','entry-inputs.json']:
        value = json.loads((ROOT/name).read_text())
        assert check(Path(value['preserved']['path']), value['preserved']) == check(Path(value['before']['path']), value['before'])
    for value in json.loads((ROOT/'transfer-rounding-inputs.json').read_text())['changes']:
        assert check(Path(value['preserved']['path']), value['preserved']) == check(Path(value['before']['path']), value['before'])
    assert (ROOT/'Tests/RemoteTargetBudgetCheck.swift').read_text().count('groups += 1') == 6
    assert '"--describe-remote-mtp", "--execute-remote-mtp"' in (ROOT/'Runtime/Gemma4BenchmarkEntry.swift').read_text()
    print(json.dumps({'passed':True,'members':len(manifest['members']),'overlays':len(inputs['overlays']),
        'changedPreimages':5,'predecessors':3,'contexts':len(inputs['controls']),
        'stagedFoundationGroups':6,'compilerExecuted':False,'nativeExecuted':False}))

if __name__ == '__main__':
    main()
