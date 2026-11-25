import DarkbloomClusterProtocol
import Foundation

@_spi(Benchmark) public struct QwenResidentMTPProbeCompletion: Sendable {
    public let completion: QwenResidentGenerationCompletion
    public let encodedEvidence: Data
}

/// Private probe component of the existing resident owner. The owner supplies
/// its operation lock, control, lifecycle and already-owned collective.
final class QwenResidentMTPProbeRuntime {
    private let admission: QwenResidentAdmission
    private let control: QwenResidentControl
    private let collective: Collective
    private let lifecycle: QwenLayerStageResidentLifecycle
    private var loaded: QwenResidentLoadedStage?
    private var assets: QwenResidentStageWithMTPAssets?
    private let capacity: Int
    private struct Reservation {
        let request: QwenLayerStageGenerationRequest
        let agreement: QwenLayerStageGenerationAgreement
        let base: QwenResidentRequestAllowance
        let mtp: QwenResidentMTPRequestResources?
        let charged: Int
        let deadline: UInt64
    }
    private var reservation: Reservation?
    private var used = false
    var admitsAnotherRequest: Bool { !used && loaded != nil }

    init(admission: QwenResidentAdmission, control: QwenResidentControl, collective: Collective,
         lifecycle: QwenLayerStageResidentLifecycle, loaded: QwenResidentLoadedStage,
         assets: QwenResidentStageWithMTPAssets?, capacity: Int) {
        self.admission = admission; self.control = control; self.collective = collective
        self.lifecycle = lifecycle; self.loaded = loaded; self.assets = assets; self.capacity = capacity
    }

    static func agreement(admission: QwenResidentAdmission, loaded: QwenResidentLoadedStage,
                          request: QwenLayerStageGenerationRequest) throws -> QwenLayerStageGenerationAgreement {
        let receipt = loaded.loaded.receipt
        let source = try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: receipt.sourceConfigurationSHA256,
            artifactAggregateSHA256: receipt.verifiedAggregateSHA256,
            storageCommitmentSHA256: receipt.storageCommitmentSHA256,
            planFingerprint: admission.plan.fingerprint, producerStageFingerprint: admission.plan.stages[0].fingerprint)
        return try .init(request: request, membershipEpoch: admission.configuration.identity.membershipEpoch,
            source: source, consumerStageFingerprint: admission.plan.stages[1].fingerprint,
            rankBuildSHA256: admission.configuration.identity.peers.map(\.buildSHA256),
            numericalPolicySHA256: admission.arithmeticSHA256, prefillPolicy: .serial)
    }

    /// Readiness quotes the full existing profile envelope; only the probe's
    /// smaller P32/C16/O2 request is admitted by reserve. No state is allocated.
    static func maximumCapacity(admission: QwenResidentAdmission, loaded: QwenResidentLoadedStage,
                                assets: QwenResidentStageWithMTPAssets?, base: QwenResidentRequestAllowance) throws -> Int {
        if admission.configuration.rank == 0 { return base.reservedBytes }
        guard let assets else { throw ProbeError("MTP probe final rank has no loaded assistant") }
        let profile = admission.profile
        let envelope = try QwenLayerStageGenerationRequest(profile: profile,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            promptTokenIDs: Array(repeating: 0, count: profile.maximumPromptTokens),
            chunkSize: profile.maximumChunkTokens, outputCount: profile.maximumOutputTokens, stopTokenIDs: [])
        let agreement = try agreement(admission: admission, loaded: loaded, request: envelope)
        return try QwenResidentMTPRequestResources(assets: assets, plan: admission.plan, agreement: agreement,
            capacityLimitBytes: Int.max).requiredReservationBytes
    }

    func reserve(requestID: UUID, request value: ClusterWorkerReservation) throws -> Int {
        guard !used, reservation == nil, let loaded else { throw ProbeError("MTP probe owner permits one request") }
        let request = try admission.request(value, id: requestID, now: DispatchTime.now().uptimeNanoseconds)
        guard request.promptCount <= 32, request.chunkSize <= 16, request.outputCount == 2,
              request.stopTokenIDs.isEmpty else { throw ProbeError("MTP probe requires P<=32/C<=16/O2/empty stops") }
        try control.check(); try control.reserve(requestID)
        do {
            let agreement = try Self.agreement(admission: admission, loaded: loaded, request: request)
            let base = try QwenResidentRequestAllowance.derive(profile: loaded.profile, plan: admission.plan,
                rank: collective.rank, maximumTokens: request.maximumTokens,
                chunkSize: min(request.chunkSize, request.promptCount), bound: QwenResidentResourceEnvironment.allocationBound)
            let mtp = try assets.map { try QwenResidentMTPRequestResources(assets: $0, plan: admission.plan,
                agreement: agreement, capacityLimitBytes: value.capacityLimitBytes) }
            let charged = mtp?.requiredReservationBytes ?? base.reservedBytes
            guard charged <= value.capacityLimitBytes, charged <= capacity else {
                throw ProbeError("MTP probe exceeds retained caller or Ready capacity")
            }
            try mtp?.requireLive(); try base.requireLive(); try control.check(deadline: value.deadlineUptimeNanoseconds)
            reservation = .init(request: request, agreement: agreement, base: base, mtp: mtp,
                charged: charged, deadline: value.deadlineUptimeNanoseconds)
            return charged
        } catch { control.fail(); throw error }
    }

    func start(requestID: UUID, onCommittedToken: (Int, Int, Int) throws -> Bool) throws -> QwenResidentMTPProbeCompletion {
        guard let reserved = reservation, reserved.request.requestID == requestID, let loaded else {
            throw ProbeError("MTP probe start lacks its retained reservation")
        }
        used = true
        let result = try QwenResidentRequestPublication.run(control: control, lifecycle: lifecycle,
            identity: .init(requestID: requestID, epoch: requestID, recordedRequestFingerprint: reserved.request.fingerprint),
            deadline: reserved.deadline, body: {
                try autoreleasepool {
                    var ordinal = 0
                    func check() throws {
                        try control.check(deadline: reserved.deadline)
                        try reserved.mtp?.requireLive(); try reserved.base.requireLive()
                        try control.check(deadline: reserved.deadline)
                    }
                    return try probeQwenLayerStageMTPRequest(loaded: loaded.loaded, assets: assets,
                        plan: admission.plan, agreement: reserved.agreement, collective: collective,
                        capacityLimitBytes: reserved.charged, deadlineUptimeNanoseconds: reserved.deadline,
                        onCommittedToken: { token in
                            let current = ordinal; ordinal += 1
                            return try onCommittedToken(current, token, reserved.request.promptCount + current)
                        }, check: check)
                }
            }, prepare: { evidence in
                let value = evidence.execution
                guard value.bothRequestStatesRetired, let reason = ClusterWorkerFinishReason(rawValue: value.finishReason.rawValue) else {
                    throw ProbeError("MTP probe lacks bilateral retirement")
                }
                let encoded = try canonicalJSONData(evidence)
                guard encoded.count <= 1_048_576 else { throw ProbeError("MTP probe CPU evidence exceeded 1MiB") }
                let completion = QwenResidentGenerationCompletion(requestID: requestID, finishReason: reason,
                    selectedTokenIDs: value.selectedTokenIDs, completedFrames: value.completedFrames,
                    committedTokens: value.committedTokens, tokenChainSHA256: value.tokenChainSHA256,
                    bothRequestStatesRetired: true)
                return QwenResidentMTPProbeCompletion(completion: completion, encodedEvidence: encoded)
            })
        reservation = nil
        return result
    }

    func release() { reservation = nil; assets = nil; loaded = nil }
}
