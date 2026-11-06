#!/usr/bin/env python3
"""Read only small source files; no candidate import, process, compiler or model."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
def body(text, marker):
    at = text.index('{', text.index(marker)); level = 1; end = at + 1
    while level:
        level += (text[end] == '{') - (text[end] == '}'); end += 1
    return text[at:end]
def read(name):
    return (ROOT / name).read_text()
spec = json.loads(read('source-inputs.json'))
for item in spec['files']:
    path = ROOT / item['path']
    assert path.stat().st_size == item['bytes'] and sha(path) == item['sha256'], item
for item in spec['dependencies']:
    assert sha(Path(item['path'])) == item['sha256'], item
for item in spec['overlays']:
    if 'original' in item:
        assert sha(ROOT/item['original']) == item['beforeSHA256'], item
entry = read('Runtime/Gemma4RegisteredForwardEntry.swift')
entry = entry.replace('    probeExpertOperation: (any Gemma4ExpertForwardOperation)? = nil,\n'
                      '    requestExpertOperation: (any Gemma4ExpertForwardOperation)? = nil,\n', '')
entry = entry.replace('                        incoming: probeInput, observeIngress: observeProbeOutput,\n'
                      '                        expertOperation: probeExpertOperation, check: checked)',
                      '                        incoming: probeInput, observeIngress: observeProbeOutput, check: checked)')
entry = entry.replace('                        probe: probe, residualDType: residualDType, expertOperation: requestExpertOperation,\n'
                      '                        admitGeometry: admitRequest, check: checked)',
                      '                        probe: probe, residualDType: residualDType, admitGeometry: admitRequest, check: checked)')
assert entry == read('originals/Gemma4RegisteredForwardEntry.swift'), 'Original forward/cleanup inverse'
owner = read('Runtime/Gemma4ShortResourceOwner.swift')
old_owner = read('originals/Gemma4ShortResourceOwner.swift')
pressure = '''            if budget.expertResources != nil, os.pressureLevel != 1 {
                throw ProbeError("Gemma EP requires actual normal pressure level1")
            }
'''
assert body(owner,'    func check()').replace(pressure,'') == body(old_owner,'    func check()'), 'Live budget/floor checks changed'
budget = read('Runtime/Gemma4ShortResourceBudget.swift')
old_budget = read('originals/Gemma4ShortResourceBudget.swift')
budget = budget.replace('    let target: Gemma4ForwardTarget\n    let expertResources: Gemma4ExpertResourceTerms?\n','')
budget = budget.replace('        case .expertParallel: globals = Array(0..<30); ownsHead = true\n',
    '        case .expertParallel:\n            throw ProbeError("Gemma EP requires a separately admitted replicated-state and expert-exchange budget")\n')
budget = budget.replace('item.selectedShape','item.source.layout.shape')
budget = budget.replace('if target != .stage(1) {','if target == .fullReference || target == .stage(0) {')
budget = budget.replace('''        let expertResources: Gemma4ExpertResourceTerms?
        if case .expertParallel(let partition) = target {
            expertResources = try .derive(partition: partition, frameTokens: max(2, m))
            arrays += expertResources!.arrayTerms
        } else { expertResources = nil }
''','')
budget = budget.replace('$0.selectedByteCount','$0.source.layout.byteCount')
budget = budget.replace(', expertResources?.hostBytes ?? 0','')
budget = budget.replace('return .init(target: target, expertResources: expertResources, selected:', 'return .init(selected:')
assert budget == old_budget, 'Original ledger inverse'
refusal = '        case .expertParallel:\n            throw ProbeError("Gemma EP requires a separately admitted replicated-state and expert-exchange budget")\n'
assert read('Runtime/Gemma4BenchmarkResourceBudget.swift').replace(refusal,'') == read('originals/Gemma4BenchmarkResourceBudget.swift')
assert 'Gemma4BenchmarkGuardMetrics.hostAllowanceBytes' in read('Runtime/Gemma4BenchmarkResourceBudget.swift')
wire = read('Runtime/Gemma4ExpertWire.swift')
payload = read('Runtime/Gemma4ExpertWirePayload.swift')
assert 'Collective(' not in wire + payload and 'sendCompleted' in payload and 'receiveCompleted' in payload
assert 'withExtendedLifetime(owned)' in payload and 'header.event("rows-consumed")' in payload
assert 'catch { poison(); throw error }' in wire
native = read('Runtime/Gemma4ExpertCorrectnessEntry.swift')
assert native.count('Gemma4ShortResourceOwner(') == native.count('Collective(transport:') == 1
assert native.index('Gemma4ShortResourceOwner(') < native.index('Collective(transport:')
assert native.index('guard releasedGroup == nil') < native.index('owner.completed()')
assert 'try native.check(); throw error' in native and 'alarm(UInt32(job.timeoutSeconds))' in native
assert not any(p.name.startswith('ExpertAxis') for p in (ROOT/'Runtime').glob('*.swift'))
assert 'import MLX' not in read('Tests/ExchangeScheduleChecks.swift')
print(json.dumps(dict(sourceOnly=True, files=len(spec['files']), overlays=len(spec['overlays']),
    forwardAndCleanupInverse=True, existingOwnerCheckInverse=True, originalLedgerInverse=True,
    currentBenchmarkGuardAllowancePreserved=True, compilerExecuted=False, nativeExecuted=False),sort_keys=True))
