"""Copy five current owners and add optional selected-observer wiring only.

Out-of-tree draft generator; never run this against already integrated hooks.
No native calls, model data or candidate output are accessed.
"""
import difflib
import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parent.parent / 'd-inference/experiments/cluster/inference/Sources/ClusterInference'
NAMES = ['QwenLongPrefillSoloRequest.swift', 'QwenLongPrefillRankRequest.swift',
         'QwenLongPrefillRankSender.swift', 'QwenLongPrefillRankReceiver.swift',
         'QwenLayerStageProfiledPrefillComputeContext.swift']


def replace(text, old, new, count=1):
    if text.count(old) != count:
        raise ValueError('Unexpected original source occurrence: ' + old)
    return text.replace(old, new)


def changed(name, text):
    if name in NAMES[:2]:
        text = replace(text,
            '    onReady: () throws -> Void = {}, phaseRecorder: QwenPrefillPhaseRecorder? = nil,\n',
            '    onReady: () throws -> Void = {}, phaseRecorder: QwenPrefillPhaseRecorder? = nil,\n'
            '    ownerObserverFactory: QwenPrefillOwnerObserverFactory? = nil,\n')
    if name == NAMES[0]:
        text = replace(text,
            '                    let output = try fresh.prefillChunk(step.tokenIDs, final: step.frame.finalPromptChunk, check: checked)',
            '                    let observer = try qwenPrefillSelectedOwnerObserver(for: step.frame, factory: ownerObserverFactory)\n'
            '                    let output = try fresh.prefillChunk(step.tokenIDs, final: step.frame.finalPromptChunk,\n'
            '                        observer: observer, check: checked)')
    elif name == NAMES[1]:
        for role in ['Sender', 'Receiver']:
            text = replace(text,
                'runQwenLongPrefillRank' + role + '(context: fresh, transport: transport, trace: trace, check: checked)',
                'runQwenLongPrefillRank' + role + '(context: fresh, transport: transport, trace: trace,\n'
                '                    ownerObserverFactory: ownerObserverFactory, check: checked)')
    elif name in NAMES[2:4]:
        text = replace(text,
            '    transport: QwenLayerStageProfiledPrefillTransport, trace: QwenLongPrefillRankTrace,\n',
            '    transport: QwenLayerStageProfiledPrefillTransport, trace: QwenLongPrefillRankTrace,\n'
            '    ownerObserverFactory: QwenPrefillOwnerObserverFactory? = nil,\n')
        if name == NAMES[2]:
            text = replace(text, '        prepared = try context.prepare(step, check: check)',
                '        let observer = try qwenPrefillSelectedOwnerObserver(for: step.frame, factory: ownerObserverFactory)\n'
                '        prepared = try context.prepare(step, observer: observer, check: check)')
        else:
            text = replace(text, '            let commit = try context.consume(step, boundary: boundary, check: check)',
                '            let observer = try qwenPrefillSelectedOwnerObserver(for: step.frame, factory: ownerObserverFactory)\n'
                '            let commit = try context.consume(step, boundary: boundary, observer: observer, check: check)')
    else:
        text = replace(text,
            '    func prepare(_ step: QwenLayerStageProfiledPrefillRecordedRequest.Step,\n',
            '    func prepare(_ step: QwenLayerStageProfiledPrefillRecordedRequest.Step,\n'
            '                 observer: CBv2OwnerPhaseObserver? = nil,\n')
        text = replace(text,
            '    func consume(_ step: QwenLayerStageProfiledPrefillRecordedRequest.Step, boundary: QwenLayerStageBoundary,\n',
            '    func consume(_ step: QwenLayerStageProfiledPrefillRecordedRequest.Step, boundary: QwenLayerStageBoundary,\n'
            '                 observer: CBv2OwnerPhaseObserver? = nil,\n')
        text = replace(text, '                    final: step.frame.finalPromptChunk, check: checked)',
            '                    final: step.frame.finalPromptChunk, observer: observer, check: checked)')
        text = replace(text, '                    final: step.frame.finalPromptChunk, incoming: boundary, check: checked)',
            '                    final: step.frame.finalPromptChunk, incoming: boundary, observer: observer, check: checked)')
    return text


def main():
    originals = HERE / 'original-owner-sources'
    proposed = HERE / 'proposed-owner-sources'
    originals.mkdir(exist_ok=True)
    proposed.mkdir(exist_ok=True)
    pins, patch = {}, []
    for name in NAMES:
        raw = (SOURCE / name).read_bytes()
        original = raw.decode('utf-8')
        result = changed(name, original)
        (originals / name).write_bytes(raw)
        (proposed / name).write_text(result)
        pins[name] = dict(sha256=hashlib.sha256(raw).hexdigest(), byteCount=len(raw))
        prefix = 'experiments/cluster/inference/Sources/ClusterInference/' + name
        patch.extend(difflib.unified_diff(original.splitlines(True), result.splitlines(True),
            fromfile='a/' + prefix, tofile='b/' + prefix))
    (HERE / 'original-owner-pins.json').write_text(json.dumps(pins, indent=2, sort_keys=True) + '\n')
    (HERE / 'hooks.patch').write_text(''.join(patch))


if __name__ == '__main__':
    main()
