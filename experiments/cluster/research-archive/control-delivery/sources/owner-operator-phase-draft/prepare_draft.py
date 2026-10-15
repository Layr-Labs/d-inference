"""Source-only reproducible draft generator; never changes the repository."""
from pathlib import Path
import hashlib,json,difflib
BASE=Path('/Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/Sources/ClusterInference')
OUT=Path(__file__).resolve().parent
NAMES=['CBv2RequestSession.swift','CBv2OwnedRequestState.swift','QwenLayerStageSession.swift']

def marker(phase,tokens):
    return ('        if let observer {\n'
        f'            try CBv2OwnerPhaseObservation(phase: .{phase}, tokenCount: {tokens}, committedTokens: committedTokens)\n'
        '                .deliver(to: observer, check: check)\n'
        '        }\n')

def replace(s,old,new):
    assert s.count(old)==1,(old,s.count(old));return s.replace(old,new)

def transform(name,s):
    if name=='CBv2RequestSession.swift':
        s=replace(s,'    func prefillChunk(_ tokens: [Int], final: Bool, check: () throws -> Void) throws -> MLXArray {',
            '    func prefillChunk(_ tokens: [Int], final: Bool, observer: CBv2OwnerPhaseObserver? = nil,\n                      check: () throws -> Void) throws -> MLXArray {')
        s=replace(s,'let output = try forward(tokens, requirement: final ? .lastPositionLogits : .evaluationOnly, check: check)',
            'let output = try forward(tokens, requirement: final ? .lastPositionLogits : .evaluationOnly, observer: observer, check: check)')
        s=replace(s,'    private func forward(_ tokens: [Int], requirement: CBv2PrefillRequirement?,\n                         check:',
            '    private func forward(_ tokens: [Int], requirement: CBv2PrefillRequirement?,\n                         observer: CBv2OwnerPhaseObserver? = nil, check:')
        s=replace(s,'        let output: MLXArray\n',marker('graphConstructionBegin','tokens.count')+'        let output: MLXArray\n')
        s=replace(s,'        let roots = try evaluation!.evaluate()\n',marker('graphConstructionEnd','tokens.count')+
            marker('rootStagingBegin','tokens.count')+'        let roots = try evaluation!.evaluate()\n')
        s=replace(s,'        // Mirrors EngineLoopV2.recurrentTargetForward + eagerCacheInnerState:\n',
            marker('rootStagingEnd','tokens.count')+'        // Mirrors EngineLoopV2.recurrentTargetForward + eagerCacheInnerState:\n')
        s=replace(s,'        eval([output] + roots + cacheRoots)\n',marker('evaluationBegin','tokens.count')+'        eval([output] + roots + cacheRoots)\n')
        s=replace(s,'        let width = requirement == .evaluationOnly ? 1 : vocabularySize\n',
            marker('evaluationEnd','tokens.count')+marker('validationCommitBegin','tokens.count')+
            '        let width = requirement == .evaluationOnly ? 1 : vocabularySize\n')
        anchor='            throw ProbeError("CBv2 recurrent generation was not committed completely")\n        }\n'
        s=replace(s,anchor,anchor+marker('validationCommitEnd','tokens.count'))
    elif name=='CBv2OwnedRequestState.swift':
        s=replace(s,'    func run(tokenCount: Int, check: () throws -> Void,',
            '    func run(tokenCount: Int, observer: CBv2OwnerPhaseObserver? = nil, check: () throws -> Void,')
        def m(phase):return ''.join('    '+line if line.strip() else line for line in marker(phase,'tokenCount').splitlines(keepends=True))
        s=replace(s,'            let output = try forward(caches, evaluation!)\n',m('graphConstructionBegin')+
            '            let output = try forward(caches, evaluation!)\n'+m('graphConstructionEnd')+m('rootStagingBegin'))
        s=replace(s,'            eval([output] + recurrentRoots + cacheRoots)\n',m('rootStagingEnd')+m('evaluationBegin')+
            '            eval([output] + recurrentRoots + cacheRoots)\n')
        s=replace(s,'            try validateOutput(output)\n',m('evaluationEnd')+m('validationCommitBegin')+'            try validateOutput(output)\n')
        anchor='                throw ProbeError("CBv2 recurrent generation did not commit every local layer")\n            }\n'
        s=replace(s,anchor,anchor+m('validationCommitEnd'))
    else:
        s=replace(s,'                      incoming: QwenLayerStageBoundary? = nil,\n                      check:',
            '                      incoming: QwenLayerStageBoundary? = nil, observer: CBv2OwnerPhaseObserver? = nil,\n                      check:')
        s=replace(s,'return try perform(tokens: tokens, frame: frame, incoming: incoming, check: check)',
            'return try perform(tokens: tokens, frame: frame, incoming: incoming, observer: observer, check: check)')
        s=replace(s,'    private func perform(tokens: [Int], frame: QwenLayerStageFrame, incoming: QwenLayerStageBoundary?,\n                         check:',
            '    private func perform(tokens: [Int], frame: QwenLayerStageFrame, incoming: QwenLayerStageBoundary?,\n                         observer: CBv2OwnerPhaseObserver? = nil, check:')
        s=replace(s,'state.run(tokenCount: tokens.count, check: checked, forward:',
            'state.run(tokenCount: tokens.count, observer: observer, check: checked, forward:')
    return s


def main():
    out=OUT/'proposed-owner-sources';out.mkdir(exist_ok=True)
    originals={};patch=[]
    for name in NAMES:
        raw=(BASE/name).read_bytes();s=raw.decode();new=transform(name,s)
        originals[name]=dict(sha256=hashlib.sha256(raw).hexdigest(),byteCount=len(raw))
        (out/name).write_text(new)
        prefix='experiments/cluster/inference/Sources/ClusterInference/'+name
        patch.extend(difflib.unified_diff(s.splitlines(True),new.splitlines(True),fromfile='a/'+prefix,tofile='b/'+prefix))
    (OUT/'owners.patch').write_text(''.join(patch))
    (OUT/'original-owner-pins.json').write_text(json.dumps(originals,indent=2,sort_keys=True)+'\n')

if __name__=='__main__':main()
