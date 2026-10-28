import Foundation
import MLX
import MLXNN
import MLXLLM
import MLXLMCommon

/// File-private implementation detail inside the one full-model owner.
/// Construction performs live IO and cannot be replaced by a pure decision.
private final class QwenDenseShortReferenceLoadGate {
    let budget: QwenDenseShortReferenceLoadBudget
    private var next = 0, failed = false, finished = false
    private var observations: [QwenDenseShortReferenceResourceDecision] = []

    init(budget: QwenDenseShortReferenceLoadBudget) throws {
        self.budget = budget
        let maximumBuffer = GPU.deviceInfo().maxBufferSize
        guard maximumBuffer > 0, budget.allocationBounds.allSatisfy({ $0 <= maximumBuffer }) else {
            throw ProbeError("Short full-reference allocation exceeds the device maximum buffer")
        }
        try observe()
    }

    func observe() throws {
        do {
            // At most 1847 tensors: pre-read plus two settled checks each,
            // followed by bounded setup/finalization checks, fits this bound.
            guard !failed, !finished, observations.count < 8192 else {
                throw ProbeError("Short full-reference gate is failed, consumed or exceeds its observation limit")
            }
            let os = try QwenDenseStageLoadResources.observeOS()
            let native = QwenDenseStageLoadResources.observeNative()
            observations.append(try QwenDenseShortReferenceResourcePolicy.evaluate(budget: budget,
                ordinal: next, os: os, native: native, now: DispatchTime.now().uptimeNanoseconds))
        } catch { failed = true; throw error }
    }

    func beforeRead(name: String, tensor: QwenCheckpointTensor) throws {
        do {
            guard !failed, !finished else { throw ProbeError("Short full-reference gate was consumed or failed") }
            let dtype: String
            switch tensor.dtype {
            case .uint32: dtype = "U32"
            case .bfloat16: dtype = "BF16"
            case .float16: dtype = "F16"
            case .float32: dtype = "F32"
            default: dtype = "unsupported"
            }
            try budget.requireEntry(name: name, shape: tensor.shape, sourceDType: dtype,
                byteCount: tensor.byteCount, ordinal: next)
            try observe()
            next += 1
        } catch { failed = true; throw error }
    }

    func finish() throws -> [QwenDenseShortReferenceResourceDecision] {
        do {
            guard !failed, !finished, next == budget.tensors.count else {
                throw ProbeError("Short full-reference did not consume its complete source inventory")
            }
            try observe(); finished = true
            return observations
        } catch { failed = true; throw error }
    }

    func fail() { failed = true }
}

/// Future recording stays within this private scope. Current callers receive
/// only CPU loading evidence, after the sole model has left the autorelease pool.
private func materializeShortReference(checkpoint: VerifiedCheckpoint,
    admission: QwenDenseShortReferenceAdmission, check: () throws -> Void
) throws -> QwenDenseShortReferenceLoadResult {
    let metadata = admission.metadata, plan = metadata.plan
    guard checkpoint.aggregate == metadata.specification.artifactSHA256,
          checkpoint.verifiedManifestSHA256 == metadata.specification.manifestSHA256,
          !_qwen35MTPEnabled else {
        throw ProbeError("Short full-reference requires exact verified source and MTP disabled")
    }
    try checkpoint.requireConfiguration(metadata.configuration)
    let base = try JSONDecoder().decode(BaseConfiguration.self, from: metadata.configuration)
    guard let policy = base.perLayerQuantization else {
        throw ProbeError("Short full-reference requires the retained quantization policy")
    }
    weak var retiredModel: Module?
    let result: QwenDenseShortReferenceLoadResult
    do {
        result = try autoreleasepool {
            try withRandomState(MLXRandom.RandomState(seed: 7)) {
                let model = try constructQwenModel(metadata.configuration)
                retiredModel = model; try check()
                let layers = try validateDiagnosticQwen(model: model, configuration: metadata.configuration, policy: policy)
                guard layers == plan.layers else { throw ProbeError("Short full-reference constructor layer count differs") }
                let prepared = try PreparedQwenCheckpoint(model: model, checkpoint: checkpoint,
                    originalConfiguration: metadata.configuration, policy: policy)
                try check()
                let observed = observedQwenDenseSource(prepared, model: model)
                let profile = try QwenRegisteredDenseModelProfile.admit(configuration: metadata.configuration,
                    manifest: metadata.manifest, expectedArtifactAggregateSHA256: checkpoint.aggregate,
                    canonicalTensors: observed.map(\.canonical))
                let requirement = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan, role: .fullReference)
                let identity = QwenDenseObservedSourceIdentity(aggregateSHA256: checkpoint.aggregate,
                    configurationSHA256: checkpoint.configurationSHA256,
                    verifiedManifestSHA256: checkpoint.verifiedManifestSHA256,
                    retainedSourceCount: prepared.sourceTensorCount, bf16ConversionEnabled: true)
                let source = try QwenDenseObservedSourceValidation.validateRegistered(observed,
                    identity: identity, profile: profile, requirement: requirement, plan: plan)
                _ = try validatedQwenFeedForwardScaleTypes(model, layers: layers,
                    isMoE: false, requireTwoWaySplit: false)
                let maximumBuffer = GPU.deviceInfo().maxBufferSize
                guard maximumBuffer > 0 else { throw ProbeError("Short full-reference device has no valid maximum buffer") }
                func allocationBound(_ bytes: Int) throws -> Int {
                    let bound = try Memory.allocationFootprintUpperBound(byteCount: bytes)
                    guard bound <= maximumBuffer else {
                        throw ProbeError("Short full-reference named allocation exceeds the device maximum buffer")
                    }
                    return bound
                }
                let ledger = try QwenDenseShortRequestLedger.derive(profile: profile, plan: plan,
                    request: admission.request, scope: .fullReference, allocationFootprintUpperBound: allocationBound)
                let bounds = try source.tensors.map { try allocationBound($0.canonical.byteCount) }
                let budget = try QwenDenseShortReferenceLoadBudget.derive(profile: profile, plan: plan,
                    requirement: requirement, source: source, admission: admission, ledger: ledger, allocationBounds: bounds)
                try check()
                let gate = try QwenDenseShortReferenceLoadGate(budget: budget)
                do {
                    func checked() throws { try check(); try gate.observe(); try check() }
                    let before = QwenStageMemoryObservation("before_short_full_reference_payload_load")
                    let receipt = try withoutActuallyEscaping(check) { borrowedCheck in
                        try materializeVerifiedQwenDiagnostic(model: model, prepared: prepared,
                            originalConfiguration: metadata.configuration, storage: source,
                            convertBF16: true, check: checked, beforeTensor: { name, tensor in
                                try borrowedCheck(); try gate.beforeRead(name: name, tensor: tensor); try borrowedCheck()
                            })
                    }
                    try check(); try checkpoint.checkUnchanged()
                    let observations = try gate.finish()
                    return QwenDenseShortReferenceLoadResult(receipt: receipt, budget: budget,
                        resources: observations, memory: [before, QwenStageMemoryObservation("short_full_reference_payload_loaded")])
                } catch { gate.fail(); throw error }
            }
        }
    } catch {
        let primary = error
        guard retiredModel == nil else { throw ProbeError("Short full-reference failed (\(primary)); model remained retained") }
        throw primary
    }
    guard retiredModel == nil else { throw ProbeError("Short full-reference model remained retained") }
    try check()
    return result
}

/// Loading-only support, not a new CLI or forward path. Exactly one descriptor
/// owner and model are retired before the CPU report returns. No output is emitted.
func runQwenDenseShortReferenceLoadSupport(directory: URL, admission: QwenDenseShortReferenceAdmission,
    check: () throws -> Void
) throws -> QwenDenseShortReferenceLoadReport {
    let initial = try QwenDenseStageLoadResources.requireInitial()
    let arithmetic = try QwenLongPrefillArithmeticEnvironment.admit(ProcessInfo.processInfo.environment)
    guard try canonicalJSONData(arithmetic) == canonicalJSONData(admission.metadata.arithmetic) else {
        throw ProbeError("Short full-reference arithmetic environment changed after admission")
    }
    try check()
    weak var retiredFiles: VerifiedCheckpoint?
    do {
        return try MLX.withError { nativeError in
            func checked() throws { try nativeError.check(); try check(); try nativeError.check() }
            do {
                try checked()
                guard !_qwen35MTPEnabled else { throw ProbeError("Short full-reference requires MTP disabled") }
                let runtime = QwenDenseStageLoadRuntimeObservation()
                try checked()
                let result = try autoreleasepool {
                    let metadata = admission.metadata
                    let checkpoint = try VerifiedCheckpoint(directory: directory,
                        configurationData: metadata.configuration,
                        expectedAggregateSHA256: metadata.specification.artifactSHA256,
                        maximumPayloadBytes: metadata.specification.manifestBytes,
                        expectedManifestSHA256: metadata.specification.manifestSHA256)
                    retiredFiles = checkpoint; try checked()
                    let result = try materializeShortReference(checkpoint: checkpoint, admission: admission, check: checked)
                    try checkpoint.checkUnchanged(); try checked()
                    return result
                }
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try checked()
                guard retiredFiles == nil else { throw ProbeError("Short full-reference retained its verified file owner") }
                Memory.clearCache(); try checked()
                let released = try QwenDenseStageLoadResources.requireInitial(); try checked()
                return QwenDenseShortReferenceLoadReport(model: admission.metadata.specification.model,
                    admissionFingerprint: admission.fingerprint, recordedRequestFingerprint: admission.request.fingerprint,
                    load: result.receipt, budget: result.budget, initialResources: initial, releasedResources: released,
                    loadingResources: result.resources, memory: result.memory
                        + [QwenStageMemoryObservation("short_full_reference_released_cache_cleared")], runtime: runtime)
            } catch {
                let primary = error
                do { try nativeError.check() }
                catch { throw ProbeError("Native short full-reference failure (\(error)); accompanying Swift failure: \(primary)") }
                throw primary
            }
        }
    } catch {
        let primary = error
        var cleanup: [String] = []
        do {
            try MLX.withError { error in
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check()
                Memory.clearCache(); try error.check()
            }
        } catch { cleanup.append(String(describing: error)) }
        if retiredFiles != nil { cleanup.append("verified file owner remained retained") }
        if !cleanup.isEmpty { throw ProbeError("Short full-reference load failed (\(primary)); cleanup: \(cleanup.joined(separator: "; "))") }
        throw primary
    }
}
