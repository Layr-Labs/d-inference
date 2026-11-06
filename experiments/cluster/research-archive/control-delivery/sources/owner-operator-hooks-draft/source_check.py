"""Read frozen source copies; no Swift compilation, native work or models."""
import hashlib
import json
from pathlib import Path
import re
import unittest

HERE = Path(__file__).resolve().parent
NAMES = ['QwenLongPrefillSoloRequest.swift', 'QwenLongPrefillRankRequest.swift',
         'QwenLongPrefillRankSender.swift', 'QwenLongPrefillRankReceiver.swift',
         'QwenLayerStageProfiledPrefillComputeContext.swift']
SELECT = 'let observer = try qwenPrefillSelectedOwnerObserver(for: step.frame, factory: ownerObserverFactory)'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def restore(text, name):
    # Remove only the exact additive plumbing; all remaining source must match
    # its original snapshot, including old phase actions and failure bodies.
    text = text.replace('    ownerObserverFactory: QwenPrefillOwnerObserverFactory? = nil,\n', '')
    text = text.replace('                 observer: CBv2OwnerPhaseObserver? = nil,\n', '')
    if name == NAMES[0]:
        require(text.count(SELECT) == 1, 'Solo must select at one actual call site')
        text = text.replace('                    ' + SELECT + '\n', '')
        text = text.replace('final: step.frame.finalPromptChunk,\n                        observer: observer, check: checked)',
                            'final: step.frame.finalPromptChunk, check: checked)')
    elif name == NAMES[1]:
        text = text.replace('trace: trace,\n                    ownerObserverFactory: ownerObserverFactory, check: checked)',
                            'trace: trace, check: checked)')
    elif name == NAMES[2]:
        require(text.count(SELECT) == 1, 'Sender must select in its shared preparation helper')
        text = text.replace('        ' + SELECT + '\n', '')
        text = text.replace('context.prepare(step, observer: observer, check: check)', 'context.prepare(step, check: check)')
    elif name == NAMES[3]:
        require(text.count(SELECT) == 1, 'Receiver must select within its consume callback')
        text = text.replace('            ' + SELECT + '\n', '')
        text = text.replace('context.consume(step, boundary: boundary, observer: observer, check: check)',
                            'context.consume(step, boundary: boundary, check: check)')
    else:
        text = text.replace('final: step.frame.finalPromptChunk, observer: observer, check: checked)',
                            'final: step.frame.finalPromptChunk, check: checked)')
        text = text.replace('incoming: boundary, observer: observer, check: checked)', 'incoming: boundary, check: checked)')
    return text


def check_sources(values=None, factory=None):
    pins = json.loads((HERE / 'original-owner-pins.json').read_text())
    sources = values or {name: (HERE / 'proposed-owner-sources' / name).read_text() for name in NAMES}
    for name in NAMES:
        raw = (HERE / 'original-owner-sources' / name).read_bytes()
        require(hashlib.sha256(raw).hexdigest() == pins[name]['sha256'], 'Original source changed')
        require(restore(sources[name], name) == raw.decode(), 'Existing request/phase/native/failure source changed')
        for token in ['DispatchTime.now()', '.observe(', 'trace.record(', 'try check()', 'try checked()', '.asData()', 'eval(']:
            require(sources[name].count(token) == raw.decode().count(token), 'Added existing-clock/native/check work')
    solo, rank, sender, receiver, context = [sources[name] for name in NAMES]
    require('ownerObserverFactory: QwenPrefillOwnerObserverFactory? = nil' in solo and
            'ownerObserverFactory: QwenPrefillOwnerObserverFactory? = nil' in rank, 'Request defaults must stay nil')
    require(rank.count('ownerObserverFactory: ownerObserverFactory') == 2, 'Both native roles need pass-through')
    require(sender.index('func prepare(_ step:') < sender.index(SELECT) < sender.index('prepared = try context.prepare'), 'Actual sender prepare not instrumented')
    require(sender.index(SELECT) < sender.index('for (index, step) in steps.enumerated()'), 'Lookahead must share the one preparation site')
    require(receiver.index('consume: { boundary in') < receiver.index(SELECT) < receiver.index('let commit = try context.consume'), 'Receiver selection must stay inside actual consumption')
    require(context.count('observer: CBv2OwnerPhaseObserver? = nil') == 2 and context.count('observer: observer') == 2, 'Both context paths require defaulted pass-through')
    require(SELECT not in context, 'Compute context must not create a second observer')
    factory = factory or (HERE / 'QwenPrefillOwnerObserverFactory.swift').read_text()
    require('typealias QwenPrefillOwnerObserverFactory = (QwenLayerStageFrame) throws -> CBv2OwnerPhaseObserver' in factory, 'Factory API differs')
    body = factory.split(') throws -> CBv2OwnerPhaseObserver? {', 1)
    require(len(body) == 2 and body[1].strip() == 'guard frame.sequence == 7, let factory else { return nil }\n    return try factory(frame)\n}',
            'Selector must check frame before its sole factory invocation')
    for forbidden in ['import MLX', 'DispatchTime', '.observe(', '.seal(', '.fail(', 'eval(', '.asData(', 'MLXArray', 'JSONEncoder']:
        require(forbidden not in factory, 'Selector gained recorder/native behavior')


class HookSourceChecks(unittest.TestCase):
    def bad(self, name, edit):
        values = {n: (HERE / 'proposed-owner-sources' / n).read_text() for n in NAMES}
        values[name] = edit(values[name])
        with self.assertRaises(ValueError):
            check_sources(values)

    def test_exact_additive_source(self):
        check_sources()

    def test_lost_rank_pass_through(self):
        self.bad(NAMES[1], lambda s: s.replace('ownerObserverFactory: ownerObserverFactory', 'ownerObserverFactory: nil', 1))

    def test_lost_context_pass_through(self):
        self.bad(NAMES[4], lambda s: s.replace('observer: observer', 'observer: nil', 1))

    def test_old_phase_event_changed(self):
        self.bad(NAMES[0], lambda s: s.replace('phase: "prefill.begin"', 'phase: "operator.begin"'))

    def test_model_output_changed(self):
        self.bad(NAMES[4], lambda s: s.replace('kind: "hidden"', 'kind: "logits"'))

    def test_added_sync(self):
        self.bad(NAMES[4], lambda s: s.replace('let output = try session.prefillChunk', 'Stream.gpu.synchronize(); let output = try session.prefillChunk', 1))

    def test_second_sender_selection(self):
        self.bad(NAMES[2], lambda s: s.replace('        if prepared == nil { try prepare(step) }', '        ' + SELECT + '\n        if prepared == nil { try prepare(step) }'))

    def test_failure_cleanup_changed(self):
        self.bad(NAMES[1], lambda s: s.replace('ownedTransport?.retire()', '// dropped retirement'))

    def test_other_frame_selection(self):
        source = (HERE / 'QwenPrefillOwnerObserverFactory.swift').read_text().replace('frame.sequence == 7', 'frame.sequence == 6')
        with self.assertRaises(ValueError):
            check_sources(factory=source)

    def test_factory_before_selection(self):
        source = (HERE / 'QwenPrefillOwnerObserverFactory.swift').read_text().replace('    guard frame.sequence == 7, let factory else { return nil }', '    let callback = try factory?(frame)\n    guard frame.sequence == 7, let factory else { return nil }')
        with self.assertRaises(ValueError):
            check_sources(factory=source)


if __name__ == '__main__':
    unittest.main(verbosity=2)
