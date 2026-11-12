"""Small-file source replay only. No compiler, model payload or child process."""
import ast
import difflib
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

def sha(raw):
    return hashlib.sha256(raw).hexdigest()

def main():
    source = json.loads((ROOT / 'integration.json').read_bytes())
    patch = ''
    for row in source['overlays']:
        path = ROOT / row['source']
        raw = path.read_bytes()
        assert sha(raw) == row['sha256'], path
        old = ROOT / 'preimages' / path.name
        if row['preimageSHA256'] is not None:
            before = old.read_bytes()
            assert sha(before) == row['preimageSHA256']
        else:
            assert not old.exists()
            before = b''
        patch += ''.join(difflib.unified_diff(before.decode().splitlines(True), raw.decode().splitlines(True),
            fromfile='a/' + row['destination'] if before else '/dev/null', tofile='b/' + row['destination']))
    assert patch.encode() == (ROOT / 'runtime.patch').read_bytes()
    for row in source['context']:
        raw = Path(row['path']).read_bytes()
        assert len(raw) == row['bytes'] and sha(raw) == row['sha256'], row['path']
    auxiliary = source['auxiliarySourcePackage']
    package = Path(auxiliary['path'])
    assert sha(package.read_bytes()) == auxiliary['sha256']
    aux = json.loads(package.read_bytes())
    for row in aux['overlays']:
        assert sha((package.parent / row['source']).read_bytes()) == row['sha256']
    runtime = (ROOT / 'Runtime/Gemma4LocalMTPRuntime.swift').read_text()
    assert runtime.index('owner.attachMTPAuxiliary') < runtime.index('owner.construction(')
    assert 'captureEvidence: local.job.captureEvidence' in runtime
    assert 'admitted.requireGrant(count: count, capture: capture)' in runtime
    assert 'admitted.admitVerification(plan); try checked()' in runtime
    assert 'try session.cancel()' in runtime and 'releasedModel == nil, releasedAssistant == nil' in runtime
    assert all(s not in runtime for s in ['Collective(', 'load(from:', 'BoundedControlResourceOperation'])
    evidence = (ROOT / 'Runtime/Gemma4LocalMTPEvidence.swift').read_text()
    assert 'window.base + keeping == input.request.finalCommittedTokens' in evidence
    assert 'defer { terminalWindow = nil; terminalKeep = nil }' in evidence
    assert 'session.snapshot(includeBytes: true' in evidence and 'session.finish(' not in evidence
    driver = Path(source['prerequisiteOverlays'][0]['source']).read_text()
    assert 'requireGrant(k, capture)' in driver
    assert driver.index('let last = DispatchTime.now()') < driver.index('try beforeFinish(session, selected)')
    assert driver.index('try beforeFinish(session, selected)') < driver.index('try session.finish(')
    assert 'let targetBatchNumericsQualified = false' in driver
    entry = (ROOT / 'Runtime/Gemma4BenchmarkEntry.swift').read_text()
    assert all(x in entry for x in ['--qualify-mtp-state', '--execute-local-mtp', '--qualify-mtp-conditioning'])
    assert 'Gemma4BenchmarkRuntime.execute(input,' in entry
    policy = (ROOT / 'Runtime/Gemma4LocalMTPInput.swift').read_text()
    assert '"mtp=true", "remote=false"' in policy and 'job.benchmarkJobSHA256' in policy
    assert '[128, 4096].contains(ordinary.promptCount)' in policy
    parity = (ROOT / 'Runtime/Gemma4LocalMTPConditioningCheck.swift').read_text()
    assert 'for depth in [1,2]' in parity and 'Gemma4CBv2MTPDrafter' in parity
    assert 'branch.build(grantedCount: depth)' in parity
    controls = json.loads((ROOT / 'Tests/metadata-cases.json').read_bytes())['cases']
    assert len(controls) == len({c['name'] for c in controls}) == 12
    ast.parse(Path(__file__).read_bytes(), filename=__file__)
    print(json.dumps(dict(passed=True, overlays=len(source['overlays']), contextPins=len(source['context']),
        sourceReplay=True, auxiliaryOverlays=5, metadataCasesStaged=12,
        compilerExecuted=False, nativeExecuted=False, modelPayloadRead=False, remoteExecuted=False)))

if __name__ == '__main__':
    main()
