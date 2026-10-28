#!/usr/bin/env python3
"""Source/byte checks only; no Swift, model, native process, or network work."""
from pathlib import Path
import hashlib
import json
import re

D = Path(__file__).resolve().parent

def digest(data):
    return hashlib.sha256(data).hexdigest()

def require(value, message):
    if not value:
        raise AssertionError(message)

def validate(files):
    old = (D / 'originals/VerifiedQwenLayerStageLoading.swift').read_text()
    new = files['proposed/VerifiedQwenLayerStageLoading.swift']
    start = '        let coverage = inventories.flatMap'
    end = '        // All source/stage geometry'
    require(old[:old.index(start)] == new[:new.index('        let commitment = try qwenLayerStageStorageCommitment')], 'legacy prefix differs')
    assembly = old[old.index(start):old.index(end)]
    assembly = '\n'.join(line[4:] for line in assembly.splitlines())
    assembly = assembly.replace('    let commitment = QwenLayerStageStorageCommitment(', '    return QwenLayerStageStorageCommitment(')
    require(assembly in new, 'conservation/commitment extraction differs')
    tail = old[old.index(end):old.rindex('    }\n}')]
    tail = '\n'.join(line[4:] for line in tail.splitlines())
    require(tail.count('try error.check()') == 3, 'old check count drift')
    expected = tail.replace('try error.check()', 'try check()')
    expected = expected.replace('            let read = try tensor.read(.all)',
        '            if let beforeTensor { try beforeTensor(entry) }\n            let read = try tensor.read(.all)')
    require(new.endswith(expected + '\n}\n'), 'materializer array/check/receipt sequence differs')
    require('beforeTensor: ((QwenStageActiveTensor) throws -> Void)? = nil' in new, 'legacy nil hook changed')
    main = files['proposed/Main.swift']
    insertion = '''        if QwenDenseStageLoadCLI.isRequested(arguments) {
            try QwenDenseStageLoadCLI(arguments: arguments).run()
            return
        }
'''
    require(main.count(insertion) == 1 and main.replace(insertion, '') == (D/'originals/Main.swift').read_text(), 'Main changed beyond isolated dispatch')
    require(main.index(insertion) < main.index('let options = try Options('), 'dispatch follows ordinary Options')
    cli = files['QwenDenseStageLoadCLI.swift']
    require('arguments.count == 10' in cli and 'values[key] == nil' in cli and 'Set(values.keys) == allowed' in cli, 'closed five pairs lost')
    require('arguments[$0] == "--mode" && arguments[$0 + 1] == mode' in cli, 'foreign mode interception')
    require('["0", "1"].contains(rawStage)' in cli and '(1...300).contains(timeout)' in cli and 'String(timeout) == rawTimeout' in cli, 'selection/time grammar changed')
    budget = files['QwenDenseStageLoadBudget.swift']
    for fragment in ['pair.role == .sequentialPair', 'selected.role.stageIndex == stageIndex',
        'plan.stages[0].sourceRange.upperBound == profile.geometry.layers / 2',
        'source: source, profile: profile', 'requirement: pair, plan: plan',
        'selected.selectedActiveBytes', 'entry.localName == expected.localName', 'entry.loadedDType == expected.loadedDType']:
        require(fragment in budget, 'budget/source/role gate lost: ' + fragment)
    policy = files['QwenDenseStageLoadPolicy.swift']
    for fragment in ['minimumActualFreeBytes = 6 * gib', 'loadingHeadroomBytes = 4 * gib',
        'allocatorHeadroomBytes = 2 * gib', 'os.actualFreeBytes >= freeRequired',
        'native.allocatorLimitBytes >= allocatorRequired', 'os.swapUsedBytes == 0',
        '(0...2).contains(os.pressureLevel)', 'now - os.completedNanoseconds <= maximumObservationAgeNanoseconds',
        'os.kernelFreePages == (try QwenLongPrefillCheckedBytes.sum([os.freePages, os.speculativePages]))']:
        require(fragment in policy, 'live-decision constraint lost: ' + fragment)
    require('reclaimableUsedForAdmission = false' in policy and 'os.estimatedReclaimableBytes >= freeRequired' not in policy, 'reclaimable authorizes payload')
    resources = files['QwenDenseStageLoadResources.swift']
    for fragment in ['host_statistics64(', 'mach_port_deallocate(mach_task_self_, host)', 'released == KERN_SUCCESS',
        'sysctlbyname("vm.swapusage"', 'sysctlbyname("kern.memorystatus_vm_pressure_level"',
        'let free = rawFree - speculative', 'count == expectedCount', 'swapSize == MemoryLayout<xsw_usage>.size']:
        require(fragment in resources, 'direct bounded OS observation lost: ' + fragment)
    gate = files['QwenDenseSelectedStageLoading.swift']
    require('private final class QwenDenseStageLoadGate' in gate and gate.count('let gate = try QwenDenseStageLoadGate(') == 1, 'live gate escape/factory widened')
    require(gate.index('try budget.requireEntry(entry, ordinal: next)') < gate.index('next += 1'), 'ordered permission lost')
    require('next == budget.active.count' in gate and 'observations.count < 4096' in gate and gate.count('failed = true') >= 4, 'gate completion/poison/cap lost')
    require('budget.allocationBounds.allSatisfy({ $0 <= maximumBuffer })' in gate, 'actual device buffer limit lost')
    require('withoutActuallyEscaping(check)' in gate and 'try borrowedCheck(); try gate.beforeRead(entry); try borrowedCheck()' in gate, 'scoped optional callback borrow lost')
    require('guard retired == nil else { throw ProbeError("Selected loaded stage model remained retained") }' in gate, 'selected model escapes result boundary')
    producer = files['QwenDenseStageLoadProbe.swift']
    require(producer.index('QwenDenseStageLoadResources.requireInitial()') < producer.index('MLX.withError'), 'initial OS floor follows native setup')
    require(producer.index('VerifiedCheckpoint(directory:') < producer.index('prepareQwenDenseConstructorSource('), 'constructor precedes full file verification')
    require(producer.count('VerifiedCheckpoint(directory:') == 1 and 'do { try nativeError.check() }' in producer, 'verification count/native error precedence changed')
    require(producer.index('guard retiredFiles == nil') < producer.index('return QwenDenseStageLoadReport('), 'file owner release follows report')
    require('fullModelWeightsLoaded = false, forwardExecuted = false, requestStateCreated = false' in producer, 'execution scope widened')
    entry = files['QwenDenseStageLoadEntry.swift']
    require(entry.index('alarm(UInt32(timeoutSeconds))') < entry.index('QwenDenseConstructorAdmission.admit'), 'alarm starts late')
    require('data.count < 8 * 1_048_576' in entry and 'try checked()\n        try emitJSON(result)' in entry, 'bounded publication gate lost')
    core = '\n'.join(re.sub(r'//[^\n]*', '', files[name]) for name in files if name.startswith('Qwen') and name.endswith('.swift'))
    for denied in [r'\bforward\s*\(', r'\brecurrentPrefill\s*\(', r'\bCBv2RequestSession\s*\(', r'Memory\.(?:memoryLimit|cacheLimit)\s*=', r'\bProcess\s*\(']:
        require(re.search(denied, core) is None, 'new loading entry reaches excluded operation')
    fixture = files['fixtures/StageLoadCheck.swift']
    require('accepted.count == 21, rejected.count == 122' in fixture and 'otherwise valid cut12 is outside default-half load scope' in fixture, 'fixture contract drift')

def run():
    files = {str(p.relative_to(D)): p.read_text() for p in D.glob('Qwen*.swift')}
    files.update({str(p.relative_to(D)): p.read_text() for sub in ['proposed','fixtures'] for p in (D/sub).glob('*.swift')})
    validate(files)
    mutations = [
        ('QwenDenseStageLoadCLI.swift','arguments.count == 10','arguments.count >= 10'),
        ('QwenDenseStageLoadBudget.swift','selected.role.stageIndex == stageIndex','selected.role.stageIndex != nil'),
        ('QwenDenseStageLoadBudget.swift','plan.stages[0].sourceRange.upperBound == profile.geometry.layers / 2','plan.stages[0].sourceRange.upperBound > 0'),
        ('QwenDenseStageLoadPolicy.swift','minimumActualFreeBytes = 6 * gib','minimumActualFreeBytes = 1 * gib'),
        ('QwenDenseStageLoadPolicy.swift','os.actualFreeBytes >= freeRequired','os.estimatedReclaimableBytes >= freeRequired'),
        ('QwenDenseStageLoadPolicy.swift','os.swapUsedBytes == 0','os.swapUsedBytes >= 0'),
        ('QwenDenseStageLoadResources.swift','let free = rawFree - speculative','let free = rawFree'),
        ('QwenDenseSelectedStageLoading.swift','next == budget.active.count','next <= budget.active.count'),
        ('proposed/VerifiedQwenLayerStageLoading.swift','if let beforeTensor { try beforeTensor(entry) }','if let beforeTensor { _ = beforeTensor }'),
        ('QwenDenseStageLoadProbe.swift','forwardExecuted = false','forwardExecuted = true'),
    ]
    rejected = []
    for name, old, new in mutations:
        require(old in files[name], 'missing mutation target')
        changed = dict(files); changed[name] = changed[name].replace(old, new, 1)
        try:
            validate(changed)
        except (AssertionError, ValueError):
            rejected.append(name + ': ' + old)
        else:
            raise AssertionError('mutation accepted: ' + name)
    pin_count = 0
    for name in ['fixture-source-list.json', 'source-dependencies.json']:
        data = json.loads((D/name).read_text())
        for record in data['sources'] + ([data['stdin']] if 'stdin' in data else []):
            raw = Path(record['path']).read_bytes()
            require(digest(raw) == record['sha256'] and len(raw) == record['bytes'], 'dependency drift: ' + record['path'])
            pin_count += 1
    for record in json.loads((D/'base-source-pins.json').read_text())['files']:
        require(Path(record['path']).read_bytes() == (D/'originals'/Path(record['path']).name).read_bytes(), 'repository base drift')
    return {'schema_version':1, 'kind':'registered_selected_stage_loading_source_checks', 'passed':True,
        'source_mutations_rejected':rejected, 'dependency_pin_reads':pin_count,
        'legacy_tail_equal_after_three_check_substitutions_and_optional_hook':True,
        'prospective_swift_cases':{'accepted':21,'rejected':122},
        'swift_compiler_native_or_ssh_executed':False, 'candidate_payload_accessed':False,
        'private_live_gate_and_partial_load_not_executed':True,
        'source_files':{name:digest(value.encode()) for name,value in sorted(files.items())}}

if __name__ == '__main__':
    print(json.dumps(run(), indent=2, sort_keys=True))
