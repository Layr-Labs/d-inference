"""Exact inverse of the two additive capture seams; no Swift/native execution."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE = 'libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/'


def replace_once(raw, before, after):
    assert raw.count(before) == 1, before[:100]
    return raw.replace(before, after, 1)


def check():
    records = []
    name = BASE+'CBv2OwnedRequestState.swift'
    raw = (ROOT/'proposed'/name).read_text()
    raw = replace_once(raw, '             additionalEvaluationTargets: (() -> [MLXArray])? = nil,\n', '')
    raw = replace_once(raw, '''            if let additionalEvaluationTargets {
                eval([output] + recurrentRoots + cacheRoots + additionalEvaluationTargets())
            } else {
                eval([output] + recurrentRoots + cacheRoots)
            }
''', '            eval([output] + recurrentRoots + cacheRoots)\n')
    assert raw.encode() == (ROOT/'originals'/name).read_bytes()
    records.append(dict(path=name, originalRestoredByteExactly=True))
    name = BASE+'QwenLayerStageSession.swift'
    raw = (ROOT/'proposed'/name).read_text()
    raw = replace_once(raw, '@_spi(Cluster) import MLXLLM', 'import MLXLLM')
    start = raw.index('    /// Private experimental caller must reserve MTP history/capture storage\n')
    end = raw.index('    private func perform(', start)
    raw = raw[:start]+raw[end:]
    raw = replace_once(raw, '''                         observer: CBv2OwnerPhaseObserver? = nil, capture: QwenLayerStageMTPCapture? = nil,
                         check: () throws -> Void) throws -> QwenLayerStageOutput {''',
        '                         observer: CBv2OwnerPhaseObserver? = nil, check: () throws -> Void) throws -> QwenLayerStageOutput {')
    raw = replace_once(raw, '''            let output = try state.run(tokenCount: tokens.count, observer: observer, check: checked,
                additionalEvaluationTargets: capture.map { value in { value.evaluationTargets } }, forward: { caches, evaluation in
                if let capture {
                    guard stage.stageIndex == 1, let incoming else { throw ProbeError("MTP capture requires residual ingress") }
                    let requirement: Qwen35ClusterMTPForward.Output = frame.phase == .decode ? .decodeLastLogits
                        : (frame.finalPromptChunk ? .prefillLastLogits : .prefillEvaluation)
                    let value = try Qwen35ClusterMTPForward.forward(target: stage.model, tokens: input,
                        residual: incoming.array, caches: caches.map { $0 as! any KVCache },
                        recurrentState: [evaluation], output: requirement)
                    // The nested handler owns faults from graph construction.
                    // Check it before a secondary capture validation can throw.
                    try error.check()
                    try capture.stage(value.preNormHidden)
                    return value.value
                }
''', '            let output = try state.run(tokenCount: tokens.count, observer: observer, check: checked, forward: { caches, evaluation in\n')
    raw = replace_once(raw, '                try capture?.validate()\n', '')
    assert raw.encode() == (ROOT/'originals'/name).read_bytes()
    records.append(dict(path=name, originalRestoredByteExactly=True))
    helper = ROOT/'proposed/libs/mlx-swift-lm/Libraries/MLXLLM/Models/Qwen35ClusterMTPForward.swift'
    text = helper.read_text()
    assert text.count('target.model.cbv2Forward(') == 1
    assert 'inputEmbeddings: residual' in text and 'inputEmbeddings: nil' not in text
    return dict(schema='private_mtp_capture_inverse_check_v1', preserved=records,
        proposed=[dict(path=p.relative_to(ROOT/'proposed').as_posix(), sha256=hashlib.sha256(p.read_bytes()).hexdigest())
                  for p in sorted((ROOT/'proposed').rglob('*.swift'))],
        residualTrunkCallSites=1, compilerOrNativeExecuted=False,
        numericalParityEstablished=False, qualificationScope='Source inverse only; runtime typecheck/numerical checks pending')


if __name__ == '__main__':
    print(json.dumps(check(), sort_keys=True, indent=2))
