import Foundation
import MLX

struct QwenFullGenerationReferenceResourceReceipt: Encodable {
    let policy = "qwen_full_generation_reference_resources_v1"
    let budget: QwenFullGenerationReferenceBudget
    let authorizedTensorCount: Int
    let observationCount: Int
    let minimumActualFreeBytes: Int
    let maximumObservedActiveBytes: Int
    let requestResourceAdmissionPerformed: Bool
    let actualAllocatorBoundsUsed = true
    let reclaimableUsedForAdmission = false
    let wholeProcessPeakBoundEstablished = false
}

/// One private full-model owner. The prepared source callback receives the
/// existing verified descriptors but retains only CPU profile/budget values.
final class QwenFullGenerationReferenceResources {
    let preflight: QwenFullGenerationReferencePreflight
    let deadline: UInt64
    private var budget: QwenFullGenerationReferenceBudget?
    private var nextTensor = 0
    private var loaded = false
    private var requestAdmitted = false
    private var observations = 0
    private var minimumFree = Int.max
    private var maximumActive = 0

    init(preflight: QwenFullGenerationReferencePreflight, deadline: UInt64) {
        self.preflight = preflight; self.deadline = deadline
    }

    func check() throws {
        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw ProbeError("Full reference absolute deadline expired") }
        try QwenResidentResourceEnvironment.require()
        let os = try QwenDenseStageLoadResources.requireInitial()
        let native = QwenDenseStageLoadResources.observeNative()
        guard native.activeBytes >= 0, native.cacheBytes >= 0,
              native.peakBytes >= native.activeBytes, native.allocatorLimitBytes > 0 else {
            throw ProbeError("Invalid full-reference native memory observation")
        }
        if let budget {
            let free = try budget.requiredActualFreeBytes(after: nextTensor)
            let allocator = try budget.requiredAllocatorBytes(after: nextTensor,
                active: native.activeBytes, cache: native.cacheBytes)
            guard os.actualFreeBytes >= free, os.physicalMemoryBytes >= free,
                  native.allocatorLimitBytes >= allocator else {
                throw ProbeError("Full reference exceeds its actual-free or allocator allowance")
            }
        }
        observations = try QwenLongPrefillCheckedBytes.sum([observations, 1])
        minimumFree = min(minimumFree, os.actualFreeBytes)
        maximumActive = max(maximumActive, native.activeBytes)
        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw ProbeError("Full reference deadline expired during resource observation") }
    }

    func prepared(_ prepared: PreparedQwenCheckpoint, storage: QwenDenseSourceReadPlan) throws {
        guard budget == nil, nextTensor == 0, !loaded, !requestAdmitted else { throw ProbeError("Full reference source prepared more than once") }
        let admission = preflight.admission
        guard prepared.checkpoint.verifiedManifestSHA256 == preflight.manifestSHA256,
              prepared.checkpoint.configurationSHA256 == admission.source.resource.sourceConfigurationSHA256,
              prepared.checkpoint.aggregate == admission.source.resource.expectedArtifactAggregateSHA256,
              prepared.sourceTensorCount == 927, prepared.canonical.count == 927 else {
            throw ProbeError("Full reference prepared descriptor identity differs from raw source admission")
        }
        let profile = try QwenRegisteredDenseModelProfile.admit(configuration: admission.source.configuration,
            manifest: preflight.manifest, expectedArtifactAggregateSHA256: prepared.checkpoint.aggregate,
            canonicalTensors: storage.tensors.map(\.canonical))
        budget = try .derive(profile: profile, plan: admission.source.plan, request: admission.request,
            requirements: admission.requirements, source: storage, bound: QwenResidentResourceEnvironment.allocationBound)
        try prepared.checkpoint.checkUnchanged()
        try check()
    }

    func beforeTensor(_ name: String, tensor: QwenCheckpointTensor) throws {
        guard let budget, !loaded, !requestAdmitted else { throw ProbeError("Full tensor read lacks its prepared resource owner") }
        try budget.requireEntry(name: name, byteCount: tensor.byteCount, ordinal: nextTensor)
        try check() // Current tensor is still in remaining R here.
        nextTensor += 1
    }

    func modelLoaded(_ receipt: VerifiedQwenDiagnosticReceipt) throws {
        guard let budget, !loaded, nextTensor == budget.sourceNames.count,
              receipt.tensorCount == nextTensor, receipt.sourceTensorCount == nextTensor,
              receipt.loadedTensorBytes == (try QwenLongPrefillCheckedBytes.sum(budget.sourceByteCounts)),
              receipt.sourceModelTensorBytes == receipt.loadedTensorBytes,
              receipt.configurationSHA256 == preflight.admission.source.resource.sourceConfigurationSHA256,
              receipt.verifiedAggregateSHA256 == preflight.admission.source.resource.expectedArtifactAggregateSHA256 else {
            throw ProbeError("Full reference load did not complete its exact prepared source")
        }
        loaded = true
        try check()
    }

    func admitRequest(_ requirements: QwenGenerationReferenceRequirements) throws {
        guard loaded, !requestAdmitted,
              try canonicalJSONData(requirements) == canonicalJSONData(preflight.admission.requirements) else {
            throw ProbeError("Full reference request admission repeated or substituted requirements")
        }
        try check()
        requestAdmitted = true
    }

    func completedReceipt() throws -> QwenFullGenerationReferenceResourceReceipt {
        guard let budget, loaded, requestAdmitted, observations > 0 else {
            throw ProbeError("Full reference lacks completed load/request resource admission")
        }
        return .init(budget: budget, authorizedTensorCount: nextTensor, observationCount: observations,
            minimumActualFreeBytes: minimumFree, maximumObservedActiveBytes: maximumActive,
            requestResourceAdmissionPerformed: true)
    }
}
