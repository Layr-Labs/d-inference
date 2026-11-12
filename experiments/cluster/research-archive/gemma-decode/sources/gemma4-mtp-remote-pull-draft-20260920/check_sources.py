#!/usr/bin/env python3
"""Small source checks only. Never builds, evaluates, connects, or reads weights."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parent

def checked(path, expected):
    data = path.read_bytes()
    assert len(data) == expected['bytes'], str(path)
    assert hashlib.sha256(data).hexdigest() == expected['sha256'], str(path)
    return data

def main():
    manifest = json.loads((ROOT/'manifest.json').read_text())
    for row in manifest['members']:
        checked(ROOT/row['path'], row)
    spec = json.loads((ROOT/'integration.json').read_text())
    for row in spec['controls']:
        checked(Path(row['path']), row)
    for row in spec['overlays']:
        checked(ROOT/row['source'], row)
        before = row['before']
        if before:
            assert checked(Path(before['path']), before) == (ROOT/row['source']).read_bytes()
        else:
            assert not (Path(spec['workspace'])/row['path']).exists(), row['path']
    assert hashlib.sha256((ROOT/'Sources/AsyncMTPProposalLedger.swift').read_bytes()).hexdigest() == spec['frozenLedgerSHA256']
    test = (ROOT/'Tests/PullProtocolCheck.swift').read_text()
    assert test.count('try group("') == 18
    print(json.dumps({'passed':True,'members':len(manifest['members']),'overlays':len(spec['overlays']),
        'controls':len(spec['controls']),'stagedCPUGroups':18,'compilerExecuted':False,'modelExecuted':False}))

if __name__ == '__main__':
    main()
