#!/usr/bin/env python3
"""Source-only verifier. No subprocess/compiler/native/model or imports from candidate."""
import hashlib, json
from pathlib import Path
R=Path(__file__).resolve().parents[1]
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def body(text, marker):
    at=text.index('{',text.index(marker)); depth=1; pos=at+1
    # Selected function body contains balanced interpolation braces/comments.
    while depth:
        depth += (text[pos]=='{')-(text[pos]=='}'); pos+=1
    return text[at:pos]
inputs=json.loads((R/'source-inputs.json').read_text())
for item in inputs['overlays']:
    assert sha(R/item['candidate'])==item['sha256'],item
    if item.get('original'):
        assert sha(R/item['original'])==item['beforeSHA256'],item
for item in inputs['dependencies']:
    assert sha(Path(item['path']))==item['sha256'],item
old=(R/'originals/Gemma4Text.swift').read_text(); new=(R/'SDK/Gemma4Text.swift').read_text()
old_decoder=old[old.index('public class Gemma4DecoderLayer'):]
old_body=body(old_decoder,'public func callAsFunction(')
new_body=body(new,'private func forwardWithExpertOperation(')
old_sparse='''            h2 = experts(
                h2,
                topKIndices: topKIndices,
                topKWeights: topKWeights,
                isExpertPrefill: isExpertPrefill)'''
new_sparse='''            h2 = try expertOperation(experts, h2, topKIndices, topKWeights, isExpertPrefill)'''
assert new_body.replace(new_sparse,old_sparse)==old_body,'decoder math drift'
# All original router and inner/full-model bodies remain exact.
for start,end in [('private class Gemma4Router','private class Gemma4Experts'),
                  ('private class Gemma4MLP','// MARK: - Decoder Layer'),
                  ('public class Gemma4TextModelInner','// MARK: - Bidirectional vision attention overlay'),
                  ('public class Gemma4TextModel:',None)]:
    a=old[old.index(start):old.index(end) if end else None]
    b=new[new.index(start):new.index(end) if end else None]
    assert a==b,start
session=(R/'Runtime/Gemma4OwnedForwardSession.swift').read_text()
previous=(R/'originals/Gemma4OwnedForwardSession.swift').read_text()
assert session[session.index('    func finish('):]==previous[previous.index('    func finish('):]
assert session.count('state.run(')==previous.count('state.run(')==1
assert session.count('schedule.commit(frame)')==previous.count('schedule.commit(frame)')==1
assert 'expertOperation: self.expertOperation, check: checked' in session
loader=(R/'Runtime/Gemma4RegisteredMaterialization.swift').read_text()
previous=(R/'originals/Gemma4RegisteredMaterialization.swift').read_text()
for call in ['Stream.gpu.synchronize()', 'try native.check()', 'checkpoint.checkUnchanged()',
             'beforeTensor(selected)', 'afterTensor(selected)', 'module.update(']:
    assert loader.count(call)==previous.count(call),call
assert 'tensor.read(selected.selection)' in loader and 'tensor.read(.all)' not in loader
assert 'a.selection == b.selection' in (R/'Runtime/Gemma4OrderedLoadProgress.swift').read_text()
for name in ['Gemma4ShortResourceBudget.swift','Gemma4BenchmarkResourceBudget.swift']:
    proposed=(R/'Runtime'/name).read_text(); original=(R/'originals'/name).read_text()
    delta='''        case .expertParallel:
            throw ProbeError("Gemma EP requires a separately admitted replicated-state and expert-exchange budget")
'''
    assert proposed.replace(delta,'')==original,name
operation=(R/'Runtime/Gemma4ExpertCollectiveOperation.swift').read_text()
assert 'Stream.' not in operation and 'weightedExpertSum' not in operation
assert 'plan.reassemblyIndices' in operation and 'withExtendedLifetime(local)' in operation
assert not any(p.name.startswith('ExpertAxis') for p in (R/'Runtime').glob('*.swift'))
print(json.dumps({'sourceOnly':True,'overlays':len(inputs['overlays']),
    'decoderMathInverse':True,'ordinaryRouterTrunkExact':True,'retirementBodyExact':True,
    'existingBudgetsRefuseEP':True,'compilerExecuted':False,'nativeExecuted':False},sort_keys=True))
