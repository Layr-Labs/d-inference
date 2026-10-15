"""Bounded source/order checks; does not compile or execute native code."""
from pathlib import Path
import hashlib,json,re,unittest

ROOT=Path(__file__).resolve().parent
NAMES=['CBv2RequestSession.swift','CBv2OwnedRequestState.swift','QwenLayerStageSession.swift']
PHASES=['graphConstructionBegin','graphConstructionEnd','rootStagingBegin','rootStagingEnd',
        'evaluationBegin','evaluationEnd','validationCommitBegin','validationCommitEnd']
MARKER=re.compile(r'^( +)if let observer \{\n\1    try CBv2OwnerPhaseObservation\(phase: \.(\w+), tokenCount: ([\w.]+), committedTokens: committedTokens\)\n\1        \.deliver\(to: observer, check: check\)\n\1}\n',re.M)


def require(ok,message):
    if not ok:raise ValueError(message)


def strip_added_markers(text,name):
    found=list(MARKER.finditer(text))
    require([m.group(2) for m in found]==PHASES,'Eight ordered nil-guarded markers required')
    wanted='tokens.count' if name=='CBv2RequestSession.swift' else 'tokenCount'
    require(all(m.group(3)==wanted for m in found),'Marker token count argument differs')
    return MARKER.sub('',text)


def restored(text,name):
    if name=='CBv2RequestSession.swift':
        text=strip_added_markers(text,name)
        text=text.replace('    func prefillChunk(_ tokens: [Int], final: Bool, observer: CBv2OwnerPhaseObserver? = nil,\n                      check:',
            '    func prefillChunk(_ tokens: [Int], final: Bool, check:')
        text=text.replace('requirement: final ? .lastPositionLogits : .evaluationOnly, observer: observer, check: check',
            'requirement: final ? .lastPositionLogits : .evaluationOnly, check: check')
        text=text.replace('                         observer: CBv2OwnerPhaseObserver? = nil, check:', '                         check:')
    elif name=='CBv2OwnedRequestState.swift':
        text=strip_added_markers(text,name)
        text=text.replace('func run(tokenCount: Int, observer: CBv2OwnerPhaseObserver? = nil, check:', 'func run(tokenCount: Int, check:')
    else:
        require('CBv2OwnerPhaseObservation(' not in text,'Stage pass-through added its own observations')
        text=text.replace('incoming: QwenLayerStageBoundary? = nil, observer: CBv2OwnerPhaseObserver? = nil,',
            'incoming: QwenLayerStageBoundary? = nil,')
        text=text.replace('frame: frame, incoming: incoming, observer: observer, check: check',
            'frame: frame, incoming: incoming, check: check')
        text=text.replace('                         observer: CBv2OwnerPhaseObserver? = nil, check:', '                         check:')
        text=text.replace('state.run(tokenCount: tokens.count, observer: observer, check:', 'state.run(tokenCount: tokens.count, check:')
    return text


def check_owner(text,name,original):
    require(restored(text,name)==original,'Original model, eval, validation, schedule or failure body changed')
    if name=='QwenLayerStageSession.swift':return
    def pos(item):
        at=text.find(item);require(at>=0,'Missing source item: '+item);return at
    def marker(phase):return pos('phase: .'+phase+',')
    # Narrow to the instrumented forward/run body before testing operation order.
    offset=pos('    private func forward(') if name=='CBv2RequestSession.swift' else pos('    func run(')
    body=text[offset:]
    forward='if let requirement {' if name=='CBv2RequestSession.swift' else 'let output = try forward(caches, evaluation!)'
    roots='let roots = try evaluation!.evaluate()' if name=='CBv2RequestSession.swift' else 'let recurrentRoots = try evaluation!.evaluate()'
    expression='eval([output] + roots + cacheRoots)' if name=='CBv2RequestSession.swift' else 'eval([output] + recurrentRoots + cacheRoots)'
    require(marker('graphConstructionBegin')<pos(forward)<marker('graphConstructionEnd')<marker('rootStagingBegin')<pos(roots)
        <pos('let cacheRoots = caches.flatMap')<marker('rootStagingEnd')<marker('evaluationBegin')<pos(expression),
        'Graph/root/evaluation order differs')
    evaluation=pos(expression);check=text.find('try check()',evaluation)
    require(evaluation<check<marker('evaluationEnd')<marker('validationCommitBegin'), 'Existing error check must precede evaluationEnd')
    validate='let width = requirement' if name=='CBv2RequestSession.swift' else 'try validateOutput(output)'
    require(marker('validationCommitBegin')<pos(validate)<pos('try validateState(after:')
        <pos('try evaluation!.commit()')<pos('committedTokens +=')<marker('validationCommitEnd'),
        'Validation/commit or advanced-frontier marker order differs')
    tail=body[body.find('phase: .validationCommitEnd,'):]
    require(tail.find('return output')>0,'Final observer must precede returning native output')
    # The successful path adds no error checks or native evaluation/synchronization.
    for token in ['eval(','.synchronize()','.asData()', 'try check()']:
        require(text.count(token)==original.count(token),'Additional native evaluation/check on success path')


def check_types(text):
    require(re.findall(r'^    case (\w+) =',text,re.M)==PHASES,'Closed phase enum differs')
    require('import MLX' not in text and 'DispatchTime' not in text and 'Encodable' not in text,'Core gained native, clock or serialization behavior')
    require(text.count('try check()')==1,'Unexpected callback-check count')
    exact='''        do {
            try observer(self)
        } catch {
            let observationError = error
            try check()
            throw observationError
        }'''
    require(exact in text,'Observer failure no longer preserves existing native/deadline precedence')


def check_all(values=None,types=None):
    pins=json.loads((ROOT/'original-owner-pins.json').read_text())
    for name in NAMES:
        raw=(ROOT/'original-owner-sources'/name).read_bytes()
        require(hashlib.sha256(raw).hexdigest()==pins[name]['sha256'],'Original snapshot changed')
        text=(ROOT/'proposed-owner-sources'/name).read_text() if values is None else values[name]
        check_owner(text,name,raw.decode())
    check_types((ROOT/'CBv2OwnerPhaseObservation.swift').read_text() if types is None else types)


class SourceMutationTests(unittest.TestCase):
    def test_current_sources(self):check_all()
    def bad(self,name,edit):
        values={n:(ROOT/'proposed-owner-sources'/n).read_text() for n in NAMES};values[name]=edit(values[name])
        with self.assertRaises(ValueError):check_all(values)
    def test_eval_omission(self):self.bad(NAMES[0],lambda s:s.replace('eval([output] + roots + cacheRoots)','eval(output)'))
    def test_extra_sync(self):self.bad(NAMES[1],lambda s:s.replace('let output = try forward','Stream.gpu.synchronize(); let output = try forward'))
    def test_marker_order(self):self.bad(NAMES[0],lambda s:s.replace('.graphConstructionEnd,','.rootStagingBegin,',1))
    def test_nil_guard_removed(self):self.bad(NAMES[1],lambda s:s.replace('if let observer {','if true {',1))
    def test_count_argument_changed(self):self.bad(NAMES[0],lambda s:s.replace('tokenCount: tokens.count','tokenCount: tokens.count + 1',1))
    def test_commit_marker_before_commit(self):
        def edit(s):
            m=list(MARKER.finditer(s))[-1];block=m.group(0);s=s[:m.start()]+s[m.end():]
            return s.replace('            try evaluation!.commit()',block+'            try evaluation!.commit()')
        self.bad(NAMES[1],edit)
    def test_error_check_moved_after_observer(self):
        def edit(s):
            s=s.replace('        try check()\n        if let observer {\n            try CBv2OwnerPhaseObservation(phase: .evaluationEnd,',
                '        if let observer {\n            try CBv2OwnerPhaseObservation(phase: .evaluationEnd,',1)
            return s
        self.bad(NAMES[0],edit)
    def test_failure_flag_removed(self):self.bad(NAMES[1],lambda s:s.replace('isFailed = true','isFailed = false'))
    def test_stage_forward_output_changed(self):self.bad(NAMES[2],lambda s:s.replace(').lastHidden',').logits'))
    def test_observer_primary_precedence_changed(self):
        text=(ROOT/'CBv2OwnerPhaseObservation.swift').read_text().replace('            try check()\n            throw observationError','            throw observationError\n            try check()')
        with self.assertRaises(ValueError):check_all(types=text)
    def test_clock_added_to_pure_core(self):
        text=(ROOT/'CBv2OwnerPhaseObservation.swift').read_text()+'\nlet timestamp = DispatchTime.now()\n'
        with self.assertRaises(ValueError):check_all(types=text)

if __name__=='__main__':unittest.main(verbosity=2)
