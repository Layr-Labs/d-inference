import Foundation
import MLX

/// Private live gate, constructed only by the explicit diagnostic entry. It
/// observes the same OS/power/thermal policy as the resident owner and uses
/// actual per-array allocator/max-buffer bounds, never caller-supplied bounds.
final class QwenGenerationDiagnosticResources {
    let budget: QwenGenerationDiagnosticBudget
    private(set) var observationCount = 0
    private(set) var minimumActualFreeBytes = Int.max
    private(set) var minimumAllocatorLimitBytes = Int.max
    private var previousCheck: UInt64?

    init(loaded: LoadedQwenLayerStage, profile: QwenRegisteredDenseModelProfile,
         plan: QwenLayerStagePlan, request: QwenLayerStageGenerationRequest, rank: Int,
         requestAllowance: QwenResidentRequestAllowance) throws {
        guard (0...1).contains(rank), loaded.stageIndex == rank, plan.stages.count == 2,
              profile.configuration == plan.originalConfiguration,
              profile.configurationSHA256 == loaded.receipt.sourceConfigurationSHA256,
              profile.artifactAggregateSHA256 == loaded.receipt.verifiedAggregateSHA256,
              loaded.plan.fingerprint == plan.fingerprint, loaded.receipt.planSHA256 == plan.fingerprint,
              loaded.receipt.stagePlanSHA256 == plan.stages[rank].fingerprint,
              profile.vocabularySize == request.profile.vocabularySize,
              profile.geometry.hiddenSize == request.profile.hiddenSize,
              profile.requiredNativeDType == request.profile.activationDType,
              profile.requiredNativeDType == String(describing: loaded.activationDType),
              loaded.receipt.bf16ConversionEnabled == profile.requiredBF16ConversionPolicy else {
            throw ProbeError("Diagnostic registered profile differs from the loaded generation source")
        }
        let rebuilt = try profile.makePlanningPlan(stageCut: plan.stages[0].sourceRange.upperBound)
        guard rebuilt.fingerprint == plan.fingerprint else { throw ProbeError("Diagnostic profile Plan differs from loaded cut") }
        // A byte-only allowance is not a permit: rederive the exact request/rank
        // with the actual allocator, then require the owner's reservation to match.
        let actual = try QwenResidentRequestAllowance.derive(profile: profile, plan: plan, rank: rank,
            maximumTokens: request.maximumTokens, chunkSize: min(request.chunkSize, request.promptCount),
            bound: QwenResidentResourceEnvironment.allocationBound)
        guard actual.stateBytes == requestAllowance.stateBytes,
              actual.fusionBytes == requestAllowance.fusionBytes,
              actual.reservedBytes == requestAllowance.reservedBytes else {
            throw ProbeError("Diagnostic allowance differs from the actual reserved generation geometry")
        }
        // Preserve the base in full, including its largest host state-copy component.
        budget = try .derive(rank: rank, vocabularySize: request.profile.vocabularySize,
            activationDType: request.profile.activationDType,
            requestReservedBytes: actual.reservedBytes,
            bound: QwenResidentResourceEnvironment.allocationBound)
        try requireLive(force: true)
    }

    func requireLive(force: Bool = false) throws {
        let now = DispatchTime.now().uptimeNanoseconds
        if !force, let previousCheck, now >= previousCheck, now - previousCheck < 250_000_000 { return }
        try QwenResidentResourceEnvironment.require()
        let os = try QwenDenseStageLoadResources.requireInitial()
        let native = QwenDenseStageLoadResources.observeNative()
        let free = try budget.requiredActualFreeBytes(minimum: QwenDenseStageLoadPolicy.minimumActualFreeBytes,
            headroom: QwenDenseStageLoadPolicy.loadingHeadroomBytes)
        let allocator = try budget.requiredAllocatorBytes(active: native.activeBytes, cache: native.cacheBytes,
            headroom: QwenDenseStageLoadPolicy.allocatorHeadroomBytes)
        guard os.actualFreeBytes >= free, native.allocatorLimitBytes >= allocator else {
            throw ProbeError("Generation diagnostics exceed current actual-free or allocator limits")
        }
        observationCount = try QwenLongPrefillCheckedBytes.sum([observationCount, 1])
        minimumActualFreeBytes = min(minimumActualFreeBytes, os.actualFreeBytes)
        minimumAllocatorLimitBytes = min(minimumAllocatorLimitBytes, native.allocatorLimitBytes)
        previousCheck = now
    }
}
