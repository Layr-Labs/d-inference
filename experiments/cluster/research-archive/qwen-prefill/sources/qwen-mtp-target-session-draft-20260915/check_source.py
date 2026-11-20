"""Source-only preservation and independent logical geometry replay. No compiler/GPU."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
RUNTIME = Path('libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime')


def require(value, message):
    if not value: raise AssertionError(message)


def check():
    proposed = ROOT/'proposed'/RUNTIME
    originals = ROOT/'originals'/RUNTIME
    old = (originals/'QwenLayerStageSession.swift').read_text()
    new = (proposed/'QwenLayerStageSession.swift').read_text()
    start = '    func beginTargetVerification(profile:'
    end = '    func stageTargetVerification('
    old_start, old_end = old.index(start), old.index(end)
    new_start, new_end = new.index(start), new.index(end)
    require(new[:new_start]+old[old_start:old_end]+new[new_end:] == old,
            'Session changed outside the new begin factory seam')
    old_body = old[old.index('        do {',old_start):old_end]
    new_body = new[new.index('        do {',new.index('    private func beginVerification(')):new_end]
    new_body = new_body.replace('            let value = try makeExecution(spec)',
        '            let value = try QwenTargetVerificationExecution(request: spec, profile: profile, stage: stage,\n'
        '                identity: identity, state: state, schedule: schedule)')
    require(new_body == old_body, 'Session begin ownership/error body changed')
    old = (originals/'QwenTargetVerificationExecution.swift').read_text()
    new = (proposed/'QwenTargetVerificationExecution.swift').read_text()
    begin, end = '        let a = request.agreement.descriptor', '\n    func begin(ownerCheck:'
    old_body = old[old.index(begin):old.index(end)]
    new_body = new[new.index(begin):new.index(end)].replace('resources = try makeResources()',
        'resources = try .init(loaded: stage, profile: profile, request: request)')
    require(new_body == old_body, 'Execution identity/resource initialization order changed')
    require(new[new.index(end):] == old[old.index(end):], 'Actual staging/commit/native code changed')
    private_names = ['QwenTinyTargetModel.swift', 'QwenTinyTargetFixtureResources.swift',
        'QwenTinyTargetPair.swift', 'QwenTinyTargetCase.swift', 'TargetVerificationSessionCheck.swift']
    for name in private_names:
        source = (proposed/name).read_text()
        require(source.startswith('#if QWEN_TARGET_TINY_FIXTURE\n') and source.endswith('#endif\n'), 'Tiny code escaped fixture define')
        require('QwenRegisteredDenseModelProfile' not in source, 'Fixture fabricated a registered profile')
    geometry = json.loads((ROOT/'geometry-ledger.json').read_text())
    for row in geometry['rows']:
        cap=row['maximumTokens']; steps=min(2,row['outputTokens']-1)
        expected=3*6*(3*96*4+32*32*4)+2*(2*cap*64*4+4)+4096+2*2*64*4
        require(row['onePairLogicalStateAndBoundary'] == expected, 'Logical state ledger replay differs')
        require(row['twoPairLogicalStateAndBoundary'] == 2*expected, 'Simultaneous pair accounting differs')
        require(row['transactionNativeLogical'] == [steps*516,steps*1028], 'Transaction ledger differs')
    integration=json.loads((ROOT/'integration.json').read_text())
    for row in integration['files']:
        path=ROOT/'proposed'/row['path']
        require(hashlib.sha256(path.read_bytes()).hexdigest()==row['sha256'], 'Proposed source pin changed')
    base=json.loads((ROOT/'base.json').read_text())
    for row in base['files']:
        path=Path(row['path'])
        require(hashlib.sha256(path.read_bytes()).hexdigest()==row['sha256'], 'Qualified base source changed')
    result=dict(status='passed',proposedFiles=len(integration['files']),qualifiedBaseRuntimeFiles=len(base['files']),
        sessionBeginInverse=True,executionBindingAndStagingPreserved=True,tinyOnlyFiles=len(private_names),
        logicalGeometryCases=2,swiftParsed=False,swiftCompiled=False,nativeExecuted=False,remoteExecuted=False)
    (ROOT/'source-checks.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,sort_keys=True))


if __name__ == '__main__': check()
