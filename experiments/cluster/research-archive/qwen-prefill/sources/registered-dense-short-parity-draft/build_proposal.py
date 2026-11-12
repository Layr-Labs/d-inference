from pathlib import Path

ROOT = Path(__file__).resolve().parent
SOURCE = Path('/Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/Sources/ClusterInference')
OUT = ROOT / 'proposed'

def original(name):
    saved = ROOT / 'originals' / name
    if not saved.exists():
        saved.write_bytes((SOURCE / name).read_bytes())
    return saved.read_text()

def replace(text, old, new):
    assert text.count(old) == 1, old
    return text.replace(old, new)

def write(name, value):
    (OUT / name).write_text(value)

# Exact legacy finishing extraction: only indentation, check spelling, and label.
s = original('VerifiedQwenLayerStageBaseline.swift')
start = s.index('        // Full-width layer stages')
finish = s.rindex('        return loaded\n') + len('        return loaded\n')
tail = s[start:finish]
body = '\n'.join(line[4:] if line.startswith('    ') else line for line in tail.split('\n'))
body = body.replace('try error.check()', 'try check()').replace('label: directory.lastPathComponent', 'label: label')
write('QwenVerifiedBaselineFinishing.swift', '''import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// Shared exact finishing of an already verified full model. The caller owns
/// the model and the surrounding error/resource scope; this is not a loader.
func finishVerifiedQwenLayerStageBaseline(model: any LanguageModel,
    originalConfiguration: Data, receipt: VerifiedQwenDiagnosticReceipt,
    expectedAggregateSHA256: String, label: String, layers: Int, hidden: Int,
    vocabulary: Int, namespace: String, check: () throws -> Void
) throws -> LoadedModel {
''' + body + '}\n')
write('VerifiedQwenLayerStageBaseline.swift', s[:start] + '''        return try finishVerifiedQwenLayerStageBaseline(model: model,
            originalConfiguration: originalConfiguration, receipt: receipt,
            expectedAggregateSHA256: expectedAggregateSHA256, label: directory.lastPathComponent,
            layers: layers, hidden: hidden, vocabulary: vocabulary, namespace: namespace,
            check: { try error.check() })
''' + s[finish:])

# Full owner: a closed operation; the old load-only API remains a wrapper.
s = original('QwenDenseShortReferenceLoading.swift')
s = replace(s, '/// Future recording stays within this private scope. Current callers receive\n/// only CPU loading evidence, after the sole model has left the autorelease pool.', '''private enum QwenDenseShortReferenceOperation { case loadOnly, record }

private struct QwenDenseShortReferenceOwnerResult {
    let load: QwenDenseShortReferenceLoadResult
    let baseline: QwenLayerStageBaselineEvidence?
}

/// Recording is a closed operation inside the same private model scope.
/// Both operations return only CPU evidence after model retirement.''')
s = replace(s, 'admission: QwenDenseShortReferenceAdmission, check: () throws -> Void\n) throws -> QwenDenseShortReferenceLoadResult', 'admission: QwenDenseShortReferenceAdmission, operation: QwenDenseShortReferenceOperation,\n    check: () throws -> Void\n) throws -> QwenDenseShortReferenceOwnerResult')
s = replace(s, 'let result: QwenDenseShortReferenceLoadResult', 'let result: QwenDenseShortReferenceOwnerResult')
s = replace(s, '''                    let observations = try gate.finish()
                    return QwenDenseShortReferenceLoadResult(receipt: receipt, budget: budget,
                        resources: observations, memory: [before, QwenStageMemoryObservation("short_full_reference_payload_loaded")])''', '''                    var memory: [QwenStageMemoryObservation]? = nil
                    let baseline: QwenLayerStageBaselineEvidence?
                    switch operation {
                    case .loadOnly: baseline = nil
                    case .record:
                        memory = [before, QwenStageMemoryObservation("short_full_reference_payload_loaded")]
                        try checked()
                        baseline = try autoreleasepool {
                            let geometry = try QwenDenseShortBaselineGeometry(configuration: metadata.configuration)
                            let loaded = try finishVerifiedQwenLayerStageBaseline(model: model,
                                originalConfiguration: metadata.configuration, receipt: receipt,
                                expectedAggregateSHA256: checkpoint.aggregate, label: "registered-short-reference",
                                layers: plan.layers, hidden: geometry.hidden, vocabulary: admission.request.vocabularySize,
                                namespace: geometry.namespace, check: checked)
                            return try recordQwenLayerStageBaseline(loaded: loaded, plan: plan,
                                request: admission.request, check: checked)
                        }
                        try checkpoint.checkUnchanged(); try checked()
                        memory?.append(QwenStageMemoryObservation("short_full_reference_recorded_state_retired"))
                    }
                    let observations = try gate.finish()
                    return QwenDenseShortReferenceOwnerResult(load: .init(receipt: receipt, budget: budget,
                        resources: observations, memory: memory ?? [before, QwenStageMemoryObservation("short_full_reference_payload_loaded")]), baseline: baseline)''')
start = s.index('/// Loading-only support, not a new CLI')
sigend = s.index('    let initial =', start)
s = s[:start] + '''private struct QwenDenseShortReferenceReleased {
    let owned: QwenDenseShortReferenceOwnerResult
    let initial: QwenDenseStageLoadOSObservation, released: QwenDenseStageLoadOSObservation
    let memory: [QwenStageMemoryObservation], runtime: QwenDenseStageLoadRuntimeObservation
}

private func runQwenDenseShortReferenceOwner(directory: URL, admission: QwenDenseShortReferenceAdmission,
    operation: QwenDenseShortReferenceOperation, check: () throws -> Void
) throws -> QwenDenseShortReferenceReleased {
''' + s[sigend:]
s = replace(s, 'materializeShortReference(checkpoint: checkpoint, admission: admission, check: checked)', 'materializeShortReference(checkpoint: checkpoint, admission: admission, operation: operation, check: checked)')
s = replace(s, '''                return QwenDenseShortReferenceLoadReport(model: admission.metadata.specification.model,
                    admissionFingerprint: admission.fingerprint, recordedRequestFingerprint: admission.request.fingerprint,
                    load: result.receipt, budget: result.budget, initialResources: initial, releasedResources: released,
                    loadingResources: result.resources, memory: result.memory
                        + [QwenStageMemoryObservation("short_full_reference_released_cache_cleared")], runtime: runtime)''', '''                return QwenDenseShortReferenceReleased(owned: result, initial: initial, released: released,
                    memory: result.load.memory + [QwenStageMemoryObservation("short_full_reference_released_cache_cleared")],
                    runtime: runtime)''')
s += '''
/// Existing loading-only surface: no embedding arithmetic or request is added.
func runQwenDenseShortReferenceLoadSupport(directory: URL, admission: QwenDenseShortReferenceAdmission,
    check: () throws -> Void
) throws -> QwenDenseShortReferenceLoadReport {
    let value = try runQwenDenseShortReferenceOwner(directory: directory, admission: admission,
        operation: .loadOnly, check: check)
    let result = value.owned.load
    return QwenDenseShortReferenceLoadReport(model: admission.metadata.specification.model,
        admissionFingerprint: admission.fingerprint, recordedRequestFingerprint: admission.request.fingerprint,
        load: result.receipt, budget: result.budget, initialResources: value.initial, releasedResources: value.released,
        loadingResources: result.resources, memory: value.memory, runtime: value.runtime)
}

/// Concrete recording entry; no native model or arbitrary continuation escapes.
func recordQwenDenseShortBaseline(directory: URL, admission: QwenDenseShortReferenceAdmission,
    check: () throws -> Void
) throws -> QwenDenseShortBaselineCheckpoint {
    let value = try runQwenDenseShortReferenceOwner(directory: directory, admission: admission,
        operation: .record, check: check)
    guard let baseline = value.owned.baseline else { throw ProbeError("Short reference omitted its recording") }
    return QwenDenseShortBaselineCheckpoint(admission: admission, baseline: baseline,
        loading: value.owned.load, initialResources: value.initial, releasedResources: value.released,
        memory: value.memory, runtime: value.runtime)
}
'''
write('QwenDenseShortReferenceLoading.swift', s)

# Pair owner: original load-only wrapper plus one closed CPU-baseline variant.
s = original('QwenDenseShortPairLoading.swift')
start = s.index('/// Both models are private')
end = s.index('    let metadata =', start)
s = s[:start] + '''private enum QwenDenseShortPairOperation {
    case loadOnly
    case compare(QwenLayerStageBaselineEvidence)
}

private struct QwenDenseShortPairOwnerResult {
    let load: QwenDenseShortPairLoadResult
    let comparison: QwenLayerStageRecordedComparison?
}

/// Both actual models stay inside this owned scope, including comparison.
private func materializeQwenDenseShortPairOwner(_ prepared: QwenDenseConstructorSource,
    admission: QwenDenseShortReferenceAdmission, operation: QwenDenseShortPairOperation,
    check: () throws -> Void
) throws -> QwenDenseShortPairOwnerResult {
''' + s[end:]
s = replace(s, 'let result: QwenDenseShortPairLoadResult', 'let result: QwenDenseShortPairOwnerResult')
s = replace(s, '                    var loads: [QwenLayerStageLoadReceipt] = []', '''                    var loads: [QwenLayerStageLoadReceipt] = []
                    var recordedStages: [LoadedQwenLayerStage] = []
                    func checked() throws { try check(); try gate.observe(); try check() }''')
s = replace(s, '                        func checked() throws { try check(); try gate.observe(); try check() }\n', '')
s = replace(s, '                        loads.append(loaded.receipt)', '''                        loads.append(loaded.receipt)
                        if case .compare = operation { recordedStages.append(loaded) }''')
s = replace(s, '''                    let observations = try gate.finish()
                    return QwenDenseShortPairLoadResult(loads: loads, budget: budget, resources: observations, memory: memory)''', '''                    let comparison: QwenLayerStageRecordedComparison?
                    switch operation {
                    case .loadOnly: comparison = nil
                    case .compare(let baseline):
                        try checked()
                        comparison = try compareQwenLayerStageRecordedRequest(baseline: baseline,
                            stages: recordedStages, plan: plan, check: checked)
                        try prepared.source.prepared.checkpoint.checkUnchanged(); try checked()
                        memory.append(QwenStageMemoryObservation("short_pair_compared_state_retired"))
                    }
                    let observations = try gate.finish()
                    return QwenDenseShortPairOwnerResult(load: .init(loads: loads, budget: budget,
                        resources: observations, memory: memory), comparison: comparison)''')
s += '''
/// Existing loading-only surface, with no request or comparator invocation.
func materializeQwenDenseShortPair(_ prepared: QwenDenseConstructorSource,
    admission: QwenDenseShortReferenceAdmission, check: () throws -> Void
) throws -> QwenDenseShortPairLoadResult {
    try materializeQwenDenseShortPairOwner(prepared, admission: admission, operation: .loadOnly, check: check).load
}

/// Closed comparison consumes CPU evidence only; stage objects remain private.
func materializeQwenDenseShortPairComparison(_ prepared: QwenDenseConstructorSource,
    admission: QwenDenseShortReferenceAdmission, baseline: QwenLayerStageBaselineEvidence,
    check: () throws -> Void
) throws -> QwenDenseShortPairComparisonResult {
    try QwenDenseShortParityBinding.requireBaseline(baseline, admission: admission)
    let value = try materializeQwenDenseShortPairOwner(prepared, admission: admission,
        operation: .compare(baseline), check: check)
    guard let comparison = value.comparison else { throw ProbeError("Short pair omitted its comparison") }
    return .init(loading: value.load, comparison: comparison)
}
'''
write('QwenDenseShortPairLoading.swift', s)

# Pair file-owner support keeps its cleanup and native error precedence exact.
s = original('QwenDenseShortPairLoadSupport.swift')
start = s.index('/// One verified descriptor')
end = s.index('    let initial =', start)
s = s[:start] + '''private struct QwenDenseShortPairReleased {
    let loading: QwenDenseShortPairLoadResult
    let comparison: QwenLayerStageRecordedComparison?
    let initial: QwenDenseStageLoadOSObservation, released: QwenDenseStageLoadOSObservation
    let memory: [QwenStageMemoryObservation], runtime: QwenDenseStageLoadRuntimeObservation
}

private func runQwenDenseShortPairOwner(directory: URL, admission: QwenDenseShortReferenceAdmission,
    baseline: QwenLayerStageBaselineEvidence?, check: () throws -> Void
) throws -> QwenDenseShortPairReleased {
    if let baseline { try QwenDenseShortParityBinding.requireBaseline(baseline, admission: admission) }
''' + s[end:]
s = replace(s, '''                    let loaded = try materializeQwenDenseShortPair(prepared, admission: admission, check: checked)
                    try checkpoint.checkUnchanged(); try checked()
                    return loaded''', '''                    let loading: QwenDenseShortPairLoadResult
                    let comparison: QwenLayerStageRecordedComparison?
                    if let baseline {
                        let value = try materializeQwenDenseShortPairComparison(prepared, admission: admission,
                            baseline: baseline, check: checked)
                        loading = value.loading; comparison = value.comparison
                    } else {
                        loading = try materializeQwenDenseShortPair(prepared, admission: admission, check: checked)
                        comparison = nil
                    }
                    try checkpoint.checkUnchanged(); try checked()
                    return (loading, comparison)''')
s = replace(s, '''                return QwenDenseShortPairLoadReport(model: admission.metadata.specification.model,
                    referenceAdmissionFingerprint: admission.fingerprint, recordedRequestFingerprint: admission.request.fingerprint,
                    loads: result.loads, budget: result.budget, initialResources: initial, releasedResources: released,
                    loadingResources: result.resources, memory: result.memory
                        + [QwenStageMemoryObservation("short_pair_released_cache_cleared")], runtime: runtime)''', '''                return QwenDenseShortPairReleased(loading: result.0, comparison: result.1,
                    initial: initial, released: released,
                    memory: result.0.memory + [QwenStageMemoryObservation("short_pair_released_cache_cleared")], runtime: runtime)''')
s += '''
/// Existing loading-only entry; shared admission does not claim a passed baseline.
func runQwenDenseShortPairLoadSupport(directory: URL, admission: QwenDenseShortReferenceAdmission,
    check: () throws -> Void
) throws -> QwenDenseShortPairLoadReport {
    let value = try runQwenDenseShortPairOwner(directory: directory, admission: admission, baseline: nil, check: check)
    let result = value.loading
    return QwenDenseShortPairLoadReport(model: admission.metadata.specification.model,
        referenceAdmissionFingerprint: admission.fingerprint, recordedRequestFingerprint: admission.request.fingerprint,
        loads: result.loads, budget: result.budget, initialResources: value.initial, releasedResources: value.released,
        loadingResources: result.resources, memory: value.memory, runtime: value.runtime)
}

/// The baseline is CPU-only and already released; neither native owner escapes.
func compareQwenDenseShortPair(directory: URL, admission: QwenDenseShortReferenceAdmission,
    baseline: QwenLayerStageBaselineEvidence, check: () throws -> Void
) throws -> QwenDenseShortPairComparisonReport {
    let value = try runQwenDenseShortPairOwner(directory: directory, admission: admission,
        baseline: baseline, check: check)
    guard let comparison = value.comparison else { throw ProbeError("Short pair returned no comparison") }
    return .init(loading: value.loading, comparison: comparison,
        initialResources: value.initial, releasedResources: value.released, memory: value.memory, runtime: value.runtime)
}
'''
write('QwenDenseShortPairLoadSupport.swift', s)

s = original('Main.swift')
needle = '        if QwenDenseStageLoadCLI.isRequested(arguments) {'
s = replace(s, needle, '''        if QwenDenseShortParityCLI.isRequested(arguments) {
            try QwenDenseShortParityCLI(arguments: arguments).run()
            return
        }
''' + needle)
write('Main.swift', s)
