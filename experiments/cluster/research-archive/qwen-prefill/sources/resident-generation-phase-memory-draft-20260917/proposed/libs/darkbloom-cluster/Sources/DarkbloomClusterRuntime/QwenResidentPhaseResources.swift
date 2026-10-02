import Foundation
import MLX

/// Concrete resource owner for the experimental native entry. Retains only
/// scalar identity/allowances and control; no model, Session, tensor or file.
final class QwenResidentPhaseResources {
    let identity: QwenGenerationPhaseIdentity
    let budget: QwenGenerationPhaseBudget
    let totalReservedBytes: Int
    private let base: QwenResidentRequestAllowance
    private let prefill: QwenGenerationPrefillAllowance?
    private let control: QwenResidentControl
    private let deadline: UInt64
    private let memory: QwenResidentMemoryRecorder
    private var previousCheck: UInt64?
    private(set) var liveResourceChecks = 0

    init(admission: QwenResidentAdmission, stage: QwenResidentLoadedStage,
         agreement: QwenLayerStageGenerationAgreement, base: QwenResidentRequestAllowance,
         prefill: QwenGenerationPrefillAllowance?, budget: QwenGenerationPhaseBudget,
         ownerCapacity: Int, control: QwenResidentControl, deadline: UInt64, memory: QwenResidentMemoryRecorder) throws {
        try QwenResidentPhaseScope.require(admission)
        try QwenResidentPhaseScope.require(agreement.request)
        let rank = admission.configuration.rank, loaded = stage.loaded, receipt = loaded.receipt
        let descriptor = agreement.descriptor
        guard (0...1).contains(rank), stage.profile.model == .qwen38TwentySevenB,
              loaded.stageIndex == rank, loaded.plan.fingerprint == admission.plan.fingerprint,
              receipt.planSHA256 == descriptor.planFingerprint,
              descriptor.planFingerprint == admission.plan.fingerprint,
              descriptor.stageFingerprints == admission.plan.stages.map(\.fingerprint),
              receipt.stagePlanSHA256 == descriptor.stageFingerprints[rank],
              receipt.sourceConfigurationSHA256 == descriptor.sourceConfigurationSHA256,
              receipt.verifiedAggregateSHA256 == descriptor.artifactAggregateSHA256,
              receipt.storageCommitmentSHA256 == descriptor.storageCommitmentSHA256,
              stage.profile.configurationSHA256 == descriptor.sourceConfigurationSHA256,
              stage.profile.artifactAggregateSHA256 == descriptor.artifactAggregateSHA256,
              descriptor.rankBuildSHA256 == admission.configuration.identity.peers.map(\.buildSHA256),
              descriptor.membershipEpoch == admission.configuration.identity.membershipEpoch.uuidString.lowercased(),
              descriptor.numericalPolicySHA256 == admission.arithmeticSHA256,
              agreement.request.profile.fingerprint == admission.profile.fingerprint,
              budget == (try QwenResidentPhaseScope.budget()), deadline <= control.deadline else {
            throw ProbeError("Phase source, build, request or reservation differs from actual admitted owner")
        }
        let actual = try QwenResidentRequestAllowance.derive(profile: stage.profile, plan: admission.plan,
            rank: rank, maximumTokens: agreement.request.maximumTokens, chunkSize: agreement.request.chunkSize,
            bound: QwenResidentResourceEnvironment.allocationBound)
        let actualPrefill = try QwenResidentPrefillSelection.allowance(agreement.prefillPolicy, rank: rank,
            promptCount: agreement.request.promptCount, chunkSize: agreement.request.chunkSize,
            hiddenSize: admission.profile.hiddenSize,
            elementBytes: qwenStageWireElementBytes(admission.profile.activationDType),
            bound: QwenResidentResourceEnvironment.allocationBound)
        guard actual.stateBytes == base.stateBytes, actual.fusionBytes == base.fusionBytes,
              actual.reservedBytes == base.reservedBytes, actualPrefill == prefill else {
            throw ProbeError("Phase reservation changed from actual request/rank allowance")
        }
        totalReservedBytes = try QwenResidentPhaseScope.total(base: base.reservedBytes, prefill: prefill, budget: budget)
        guard totalReservedBytes <= ownerCapacity else { throw ProbeError("Phase reservation exceeds original owner capacity") }
        identity = .init(requestID: descriptor.requestID, membershipEpoch: descriptor.membershipEpoch,
            requestFingerprint: descriptor.requestFingerprint, agreementFingerprint: agreement.fingerprint,
            profileFingerprint: descriptor.profileFingerprint, sourceConfigurationSHA256: descriptor.sourceConfigurationSHA256,
            artifactAggregateSHA256: descriptor.artifactAggregateSHA256, storageCommitmentSHA256: descriptor.storageCommitmentSHA256,
            planFingerprint: descriptor.planFingerprint, stageFingerprint: descriptor.stageFingerprints[rank],
            buildSHA256: descriptor.rankBuildSHA256[rank], numericalPolicySHA256: descriptor.numericalPolicySHA256,
            rank: rank, promptCount: agreement.request.promptCount, chunkSize: agreement.request.chunkSize,
            outputCount: agreement.request.outputCount, prefillPolicy: agreement.prefillPolicy.rawValue)
        try identity.validate()
        self.base = base; self.prefill = prefill; self.budget = budget
        self.control = control; self.deadline = deadline; self.memory = memory
        guard memory.hostReservationBytes == budget.requiredHostReservationBytes else {
            throw ProbeError("Memory recorder host charge differs")
        }
        try memory.bind(identity)
        try requireLive(force: true, memoryPoint: .requestBegin)
    }

    func retiredMemory() throws -> QwenResidentMemoryTrace {
        try requireLive(force: true, memoryPoint: .requestRetired)
        return try memory.retire()
    }

    func requireLive(force: Bool = false, memoryPoint: QwenResidentMemoryPoint = .requestLive) throws {
        try MLX.withError { nativeError in
            do {
                try nativeError.check(); try control.check(deadline: deadline)
                let now = DispatchTime.now().uptimeNanoseconds
                if force || previousCheck == nil || now < previousCheck! || now - previousCheck! >= 250_000_000 {
                    try base.requireLive(additionalNativeBytes: prefill?.extraNativeBytes ?? 0,
                        additionalHostBytes: QwenLongPrefillCheckedBytes.sum([
                            prefill?.extraHostBytes ?? 0, budget.requiredHostReservationBytes]),
                        memoryObserver: memory.observer(memoryPoint))
                    liveResourceChecks = try QwenLongPrefillCheckedBytes.sum([liveResourceChecks, 1])
                    previousCheck = DispatchTime.now().uptimeNanoseconds
                }
                try nativeError.check(); try control.check(deadline: deadline); try nativeError.check()
            } catch { try nativeError.check(); throw error }
        }
    }
}
