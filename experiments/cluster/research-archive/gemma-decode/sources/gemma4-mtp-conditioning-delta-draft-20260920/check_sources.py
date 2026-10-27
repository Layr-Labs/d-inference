#!/usr/bin/env python3
"""Small-file pins and logical arithmetic only; never invokes Swift/native/GPU."""
import ast
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent

def sha(data):
    return hashlib.sha256(data).hexdigest()

def read_pin(row, local):
    path = ROOT / row['path'] if local else Path(row['path'])
    assert path.is_file() and not path.is_symlink(), str(path)
    assert path.stat().st_size <= 500_000, str(path)
    data = path.read_bytes()
    assert len(data) == row['bytes'] and sha(data) == row['sha256'], str(path)
    return data

def main():
    frozen = json.loads((ROOT / 'source-inputs.json').read_text())
    assert frozen['nativeIntegrated'] is False and frozen['controlsExecuted'] is False
    assert len({row['path'] for row in frozen['members']}) == len(frozen['members'])
    for row in frozen['members']:
        read_pin(row, True)
    for row in frozen['context']:
        read_pin(row, False)
    ast.parse((ROOT / 'check_sources.py').read_text())
    checks = (ROOT / 'Tests/DeltaPlanningChecks.swift').read_text()
    assert checks.count('try test("') == 20
    examples = json.loads((ROOT / 'memory-inputs.json').read_text())
    assert len(examples['examples']) == 8
    for row in examples['examples']:
        p, o, h = row['promptTokens'], row['outputCount'], row['hiddenElementBytes']
        f0, f1, fm, d = p + 1, p + o - 3, p + o - 1, o - 4
        assert (row['baseFrontier'], row['newFrontier'], row['maximumFrontier'], row['deltaPositions']) == (f0, f1, fm, d)
        roots, terms = row['liveAllocationInputs'], row['originalSnapshotReservationInputs']
        assert len(roots) == 13 and len(terms) == 12
        assert len({r['name'] for r in roots}) == 13
        for item in roots + terms:
            product = item['elementBytes']
            for dim in item['shape']:
                assert type(dim) is int and dim > 0
                product *= dim
            assert item['logicalBytes'] == product and item['actualAllocationBound'] is None
        snapshot = lambda f: 4096 * f + 8192 * min(f, 1024)
        assert row['tensorLogicalBytes'] == 12288 * d + 2816 * h
        assert row['liveLogicalBytes'] == snapshot(f0) + snapshot(f1) + row['tensorLogicalBytes']
        assert sum(r['logicalBytes'] for r in roots) == row['liveLogicalBytes']
        assert sum(t['logicalBytes'] for t in terms) == row['originalSnapshotLogicalBytes'] == 3 * snapshot(fm)
        assert row['actualRequiredAllocationBytes'] is None and row['actualReservedAllocationBytes'] is None
    print(json.dumps({'sourceOnly': True, 'members': len(frozen['members']), 'contextPins': len(frozen['context']), 'logicalExamples': 8, 'stagedFoundationGroups': 20, 'compilerInvoked': False, 'nativeIntegrated': False}, sort_keys=True))

if __name__ == '__main__':
    main()
