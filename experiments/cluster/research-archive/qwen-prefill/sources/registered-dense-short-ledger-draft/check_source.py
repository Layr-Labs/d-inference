#!/usr/bin/env python3
"""Static source/pin check only; never invokes a compiler or model helper."""
import ast
import hashlib
import json
from pathlib import Path

D=Path(__file__).resolve().parent

def check():
    pins=json.loads((D/'source-pins.json').read_text())
    for p in pins['files']:
        path=Path(p['path'])
        assert path.stat().st_size==p['sizeBytes'] and hashlib.sha256(path.read_bytes()).hexdigest()==p['sha256'],path
    inputs=json.loads((D/'compile-inputs.json').read_text())
    assert len(inputs['sources'])==21 and len(set(inputs['sources']))==21
    for p in inputs['sources']:assert Path(p).is_file()
    core=[D/x for x in inputs['newCoreFiles']]
    assert len(core)==5
    for p in core:
        s=p.read_text()
        imports=[x for x in s.splitlines() if x.startswith('import ')]
        assert imports==['import Foundation'],(p,imports)
        assert not any(x in s for x in ['FileHandle.', 'DispatchTime.', 'Process(', 'eval(', 'synchronize(', 'MLXArray(']),p
    s=(D/'QwenDenseShortRequestLedger.swift').read_text()
    gate=s.index('let expectedPlan ='); first=s.index('appendAllowances(owner:')
    assert gate < s.index('request.steps.map(\\.committedTokens) == [2, 3, 4]') < first
    assert 'maximumTokens: 5, chunkSize: 2' in s
    assert 'budget.conservativeStateAndBoundaryBytes <= 512 * 1024 * 1024' in s
    assert 'storage.fusionReplacementBytes' in s
    assert not any(x in s for x in ['storage.namedStateBudget','storage.finalState','storage.partialNamedBufferLedgerBytes'])
    for v in ['runtimeExecutionAuthorized = false','isWholeProcessMemoryBound = false','unknownNativeScratchIncluded = false',
              'allocatorProvenanceIndependentlyVerified = false','weightsAndLoadHostCopiesIncluded = false']:
        assert v in s,v
    t=(D/'QwenDenseShortLedgerTypes.swift').read_text()
    assert t.index('let logical = try product(shape + [elementBytes])') < t.index('let allocation = try bound(logical)')
    assert t.index('allocation >= logical') < t.index('allocationBoundBytes: try product([allocation, instances])')
    assert 'buffers.count < 256' in t and 'private(set) var buffers:' in t
    f=(D/'QwenDenseShortLedgerCheck.swift').read_text()
    assert 'accepted.count == 31, rejected.count == 42' in f
    for p in D.glob('*.py'):ast.parse(p.read_text(),feature_version=(3,9))
    return dict(kind='short_ledger_source_check',schemaVersion=1,result='passed',
                pinnedSourceFiles=len(pins['files']),compileInputFiles=21,newPureCoreFiles=5,
                swiftOrNativeExecuted=False,modelPayloadRead=False,
                sourceFixturesExpectedAccepted=31,sourceFixturesExpectedRejected=42,
                limits=['Static source assertions are not compilation or runtime proof','Independent Python vectors use invented identity allocation bounds'])

if __name__=='__main__':print(json.dumps(check(),sort_keys=True,indent=2))
