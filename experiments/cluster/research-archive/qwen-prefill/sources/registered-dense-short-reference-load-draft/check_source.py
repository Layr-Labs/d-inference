#!/usr/bin/env python3
"""Byte/source checks only. Does not compile Swift or read any model payload."""
from pathlib import Path
import difflib
import hashlib
import json
import re

D = Path(__file__).resolve().parent
ROOT = 'experiments/cluster/inference/Sources/ClusterInference/'
RUNTIME = ['QwenDenseShortReferenceAdmission.swift', 'QwenDenseShortReferenceLoadBudget.swift',
           'QwenDenseShortReferenceResourcePolicy.swift', 'QwenDenseShortReferenceLoadTypes.swift',
           'QwenDenseShortReferenceLoading.swift']

def require(value, message):
    if not value: raise AssertionError(message)

def sha(raw): return hashlib.sha256(raw).hexdigest()

def validate(files):
    old = (D/'originals/VerifiedQwenDiagnosticLoading.swift').read_text()
    new = files['proposed/VerifiedQwenDiagnosticLoading.swift']
    start = old.index('        var loadedBytes = 0, largestHostBytes = 0')
    end = old.index('\n    }\n}\n\nprivate struct DiagnosticQwenStorage', start)
    prefix = new[:new.index('        return try materializeVerifiedQwenDiagnostic(')]
    require(prefix == old[:start], 'legacy full-loader prefix/caps/topology changed')
    tail = '\n'.join(line[4:] for line in old[start:end].splitlines())
    require(tail.count('try error.check()') == 3, 'original tail check count changed')
    expected = tail.replace('try error.check()', 'try check()')
    for before, after in [('budget.sourceBytes', 'storage.sourceBytes'),
        ('budget.largestSourceBytes', 'storage.largestSourceBytes'),
        ('budget.expectedLayout', 'storage.expectedLayoutSHA256')]:
        expected = expected.replace(before, after)
    expected = expected.replace('            let read = try tensor.read(.all)',
        '            if let beforeTensor { try beforeTensor(name, tensor) }\n            let read = try tensor.read(.all)')
    actual = new[new.index('    var loadedBytes = 0, largestHostBytes = 0'):new.index('\n}\n\nprivate struct DiagnosticQwenStorage')]
    require(actual == expected, 'full materializer operation/error/receipt sequence differs')
    require('beforeTensor: ((String, QwenCheckpointTensor) throws -> Void)? = nil' in new, 'legacy nil hook changed')
    old_validator = old[old.index('private func validateDiagnosticQwen'):]
    require(new[new.index('func validateDiagnosticQwen'):] == old_validator.replace('private func validateDiagnosticQwen', 'func validateDiagnosticQwen', 1), 'topology validator changed beyond access')
    old_storage = old[old.index('private struct DiagnosticQwenStorage'):old.index('private func validateDiagnosticQwen')]
    expected_storage = old_storage.replace('let sourceBytes: Int\n    let largestSourceBytes: Int\n    let expectedLayout: String', 'let validated: QwenDenseSourceReadPlan')
    expected_storage = expected_storage.replace('sourceBytes = validated.sourceBytes; largestSourceBytes = validated.largestSourceBytes\n        expectedLayout = validated.expectedLayoutSHA256', 'self.validated = validated')
    require(new[new.index('private struct DiagnosticQwenStorage'):new.index('func validateDiagnosticQwen')] == expected_storage, 'legacy storage validation changed')
    admission = files[RUNTIME[0]]
    for fragment in ['(1...4096).contains(promptData.count)', '(1...4096).contains(teacherData.count)',
        'sha256(promptData) == promptSHA256', 'sha256(teacherData) == teacherSHA256',
        'try validateWorkerJSON(promptData); try validateWorkerJSON(teacherData)',
        'prompt.count == 3, teacher.count == 1', 'promptCount: 3, chunkSize: 2, outputCount: 2',
        'request.steps.map(\\.committedTokens) == [2, 3, 4]']:
        require(fragment in admission, 'closed request admission changed: '+fragment)
    budget = files[RUNTIME[1]]
    for fragment in ['requirement.role == .fullReference', 'role: .fullReference)',
        'source.registeredRequirementFingerprint == requirement.fingerprint',
        'source.tensors.map(\\.canonical) == profile.canonicalTensors',
        'ledger.scope == .fullReference', 'ledger.recordedRequestFingerprint == admission.request.fingerprint',
        'ledger.maximumTokens == 5', 'ledger.committedFrontiers == [2, 3, 4]',
        'plan.stages[0].sourceRange.upperBound == profile.geometry.layers / 2',
        'name == expected.name, shape == expected.shape', 'sourceDType == expected.sourceDType, byteCount == expected.byteCount']:
        require(fragment in budget, 'source/role/request budget guard changed: '+fragment)
    policy = files[RUNTIME[2]]
    for fragment in ['try QwenDenseStageLoadPolicy.requireInitial(os, now: now)',
        'max(QwenDenseStageLoadPolicy.minimumActualFreeBytes',
        'sum([remaining, host, host, budget.forwardReserveBytes, QwenDenseStageLoadPolicy.loadingHeadroomBytes])',
        'remaining, host, budget.forwardReserveBytes, QwenDenseStageLoadPolicy.allocatorHeadroomBytes])',
        'os.actualFreeBytes >= freeRequired', 'native.allocatorLimitBytes >= allocatorRequired',
        'reclaimableUsedForAdmission = false']:
        require(fragment in policy, 'actual resource bound changed: '+fragment)
    owner = files[RUNTIME[4]]
    require('private final class QwenDenseShortReferenceLoadGate' in owner and owner.count('let gate = try QwenDenseShortReferenceLoadGate(') == 1, 'gate construction widened')
    for fragment in ['observations.count < 8192', 'next == budget.tensors.count',
        'budget.allocationBounds.allSatisfy({ $0 <= maximumBuffer })',
        'try QwenDenseStageLoadResources.observeOS()', 'QwenDenseStageLoadResources.observeNative()',
        'scope: .fullReference, allocationFootprintUpperBound: allocationBound',
        'withoutActuallyEscaping(check)', 'try borrowedCheck(); try gate.beforeRead(name: name, tensor: tensor); try borrowedCheck()',
        'guard retiredModel == nil', 'guard retiredFiles == nil', 'do { try nativeError.check() }']:
        require(fragment in owner, 'private loading/resource/cleanup constraint changed: '+fragment)
    require(owner.count('failed = true') >= 4, 'gate failure poisoning changed')
    require(owner.index('try budget.requireEntry(') < owner.index('next += 1'), 'descriptor check follows advancement')
    entry = owner[owner.index('func runQwenDenseShortReferenceLoadSupport'):]
    require(entry.index('QwenDenseStageLoadResources.requireInitial()') < entry.index('MLX.withError'), 'initial actual-free screen follows native')
    require(entry.count('VerifiedCheckpoint(directory:') == 1, 'checkpoint verified more than once')
    require(entry.index('guard retiredFiles == nil') < entry.index('return QwenDenseShortReferenceLoadReport('), 'CPU return precedes file retirement')
    types = files[RUNTIME[3]]
    require('forwardExecuted = false, requestStateCreated = false, embeddingArithmeticExecuted = false' in types, 'load-only scope widened')
    core = '\n'.join(re.sub(r'//[^\n]*', '', files[name]) for name in RUNTIME)
    for denied in [r'\bforward\s*\(', r'\bCBv2RequestSession\s*\(', r'\bloadQwenLayerStageBaseline\s*\(',
        r'Memory\.(?:memoryLimit|cacheLimit)\s*=', r'\bProcess\s*\(', r'\bprint\s*\(']:
        require(re.search(denied, core) is None, 'support reaches excluded work')
    require('accepted.count == 20, rejected.count == 98' in files['ShortReferenceLoadCheck.swift'], 'fixture scope counts changed')

def run():
    names = RUNTIME + ['proposed/VerifiedQwenDiagnosticLoading.swift', 'ShortReferenceLoadCheck.swift', 'ShortReferenceLoadCheckMain.swift']
    files = {name:(D/name).read_text() for name in names}
    validate(files)
    mutations = [
        (RUNTIME[0], 'prompt.count == 3, teacher.count == 1', 'prompt.count <= 3, teacher.count == 1'),
        (RUNTIME[1], 'requirement.role == .fullReference', 'requirement.role != .stage0'),
        (RUNTIME[1], 'ledger.recordedRequestFingerprint == admission.request.fingerprint', 'true'),
        (RUNTIME[2], 'os.actualFreeBytes >= freeRequired', 'os.estimatedReclaimableBytes >= freeRequired'),
        (RUNTIME[2], 'remaining, host, host, budget.forwardReserveBytes,', 'remaining, host, host,'),
        (RUNTIME[4], 'next == budget.tensors.count', 'next <= budget.tensors.count'),
        (RUNTIME[4], 'observations.count < 8192', 'observations.count < 99999'),
        ('proposed/VerifiedQwenDiagnosticLoading.swift', 'if let beforeTensor { try beforeTensor(name, tensor) }', 'if let beforeTensor { _ = beforeTensor }'),
        (RUNTIME[3], 'forwardExecuted = false', 'forwardExecuted = true'),
    ]
    rejected = []
    for name, before, after in mutations:
        require(before in files[name], 'missing source mutation target')
        changed = dict(files); changed[name] = files[name].replace(before, after, 1)
        try: validate(changed)
        except (AssertionError, ValueError): rejected.append(name+': '+before)
        else: raise AssertionError('source mutation accepted')
    patch = ''.join(difflib.unified_diff((D/'originals/VerifiedQwenDiagnosticLoading.swift').read_text().splitlines(True),
        files['proposed/VerifiedQwenDiagnosticLoading.swift'].splitlines(True),
        fromfile='a/'+ROOT+'VerifiedQwenDiagnosticLoading.swift', tofile='b/'+ROOT+'VerifiedQwenDiagnosticLoading.swift'))
    for name in sorted(RUNTIME):
        patch += ''.join(difflib.unified_diff([], files[name].splitlines(True), fromfile='/dev/null', tofile='b/'+ROOT+name))
    require(patch == (D/'runtime.patch').read_text(), 'exact runtime patch differs')
    counts = {}
    for name in ['fixture-source-list.json', 'source-dependencies.json']:
        data=json.loads((D/name).read_text()); records=data['sources']+([data['stdin']] if 'stdin' in data else [])
        for r in records:
            raw=Path(r['path']).read_bytes()
            require(len(raw)==r['bytes'] and sha(raw)==r['sha256'], 'source/input pin changed: '+r['path'])
        counts[name]=len(records)
    require(Path(json.loads((D/'source-dependencies.json').read_text())['legacy_source']).read_bytes()==(D/'originals/VerifiedQwenDiagnosticLoading.swift').read_bytes(), 'repository original differs')
    return dict(kind='registered_short_full_reference_source_checks', schema_version=1, passed=True,
        legacy_tail_equal_after_three_checks_storage_field_substitutions_and_optional_hook=True,
        source_mutations_rejected=rejected, dependency_pin_reads=counts,
        prospective_swift_cases=dict(accepted=20,rejected=98), swift_compiler_or_native_executed=False,
        candidate_or_payload_accessed=False, private_live_gate_and_partial_load_not_executed=True,
        files={name:sha(value.encode()) for name,value in sorted(files.items())})

if __name__ == '__main__': print(json.dumps(run(), indent=2, sort_keys=True))
