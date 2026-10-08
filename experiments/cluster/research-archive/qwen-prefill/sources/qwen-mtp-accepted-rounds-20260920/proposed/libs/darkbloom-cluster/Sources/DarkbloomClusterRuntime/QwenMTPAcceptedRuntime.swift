import DarkbloomClusterProtocol
import Foundation

@_spi(Benchmark) public struct QwenMTPAcceptedCompletion: Sendable {
    public let completion: QwenResidentGenerationCompletion
    public let encodedEvidence: Data
}

/// A component of the existing exclusive resident owner, never another owner.
/// The reservation remains retained after completion until owner shutdown, so
/// CPU evidence publication cannot race reuse of the charged native lifetime.
final class QwenMTPAcceptedRuntime {
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
        let resources: QwenMTPAcceptedResources
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
            storageCommitmentSHA256: receipt.storageCommitmentSHA256, planFingerprint: admission.plan.fingerprint,
            producerStageFingerprint: admission.plan.stages[0].fingerprint)
        return try .init(request: request, membershipEpoch: admission.configuration.identity.membershipEpoch,
            source: source, consumerStageFingerprint: admission.plan.stages[1].fingerprint,
            rankBuildSHA256: admission.configuration.identity.peers.map(\.buildSHA256),
            numericalPolicySHA256: admission.arithmeticSHA256, prefillPolicy: .serial,
            speculation: .registered9BDepth1Short)
    }

    static func maximumCapacity(admission: QwenResidentAdmission, loaded: QwenResidentLoadedStage,
                                assets: QwenResidentStageWithMTPAssets?) throws -> Int {
        let request = try QwenLayerStageGenerationRequest(profile: admission.profile,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            promptTokenIDs: Array(repeating: 0, count: 32), chunkSize: 16, outputCount: 8, stopTokenIDs: [])
        let agreement = try agreement(admission: admission, loaded: loaded, request: request)
        return try QwenMTPAcceptedResources(loaded: loaded, assets: assets,
            agreement: agreement, plan: admission.plan).reservedBytes
    }

    func reserve(requestID: UUID, request value: ClusterWorkerReservation) throws -> Int {
        guard !used, reservation == nil, let loaded else { throw ProbeError("Accepted MTP owner permits one request") }
        let request = try admission.request(value, id: requestID, now: DispatchTime.now().uptimeNanoseconds)
        let agreement = try Self.agreement(admission: admission, loaded: loaded, request: request)
        try control.check(); try control.reserve(requestID)
        do {
            let resources = try QwenMTPAcceptedResources(loaded: loaded, assets: assets, agreement: agreement, plan: admission.plan)
            guard resources.reservedBytes <= value.capacityLimitBytes, resources.reservedBytes <= capacity else {
                throw ProbeError("Accepted MTP combined reservation exceeds caller or Ready capacity")
            }
            try resources.requireLive(); try control.check(deadline: value.deadlineUptimeNanoseconds)
            reservation = .init(request: request, agreement: agreement, resources: resources, deadline: value.deadlineUptimeNanoseconds)
            return resources.reservedBytes
        } catch { control.fail(); throw error }
    }

    func start(requestID: UUID, onCommittedToken: (Int, Int, Int) throws -> Bool) throws -> QwenMTPAcceptedCompletion {
        guard let reserved = reservation, reserved.request.requestID == requestID, let loaded else {
            throw ProbeError("Accepted MTP start lacks its retained reservation")
        }
        used = true
        return try QwenResidentRequestPublication.run(control: control, lifecycle: lifecycle,
            identity: .init(requestID: requestID, epoch: requestID, recordedRequestFingerprint: reserved.request.fingerprint),
            deadline: reserved.deadline, body: {
                try autoreleasepool {
                    var ordinal = 0
                    func check() throws {
                        try control.check(deadline: reserved.deadline); try reserved.resources.requireLive()
                        try control.check(deadline: reserved.deadline)
                    }
                    return try runQwenMTPAcceptedRequest(loaded: loaded, assets: assets, plan: admission.plan,
                        agreement: reserved.agreement, collective: collective, resources: reserved.resources, deadline: reserved.deadline,
                        onCommittedToken: { token in
                            let current = ordinal; ordinal += 1
                            return try onCommittedToken(current, token, reserved.request.promptCount + current)
                        }, check: check)
                }
            }, prepare: { evidence in
                let result = evidence.target.execution
                guard result.mtpEnabled, result.bothRequestStatesRetired,
                      let reason = ClusterWorkerFinishReason(rawValue: result.finishReason.rawValue) else {
                    throw ProbeError("Accepted MTP lacks actual bilateral request retirement")
                }
                try reserved.resources.requireLive(); try control.check(deadline: reserved.deadline)
                let bytes = try canonicalJSONData(evidence)
                guard bytes.count <= 16_777_216 else { throw ProbeError("Accepted MTP evidence exceeds16MiB") }
                try reserved.resources.requireLive(); try control.check(deadline: reserved.deadline)
                return .init(completion: .init(requestID: requestID, finishReason: reason,
                    selectedTokenIDs: result.selectedTokenIDs, completedFrames: result.completedFrames,
                    committedTokens: result.committedTokens, tokenChainSHA256: result.tokenChainSHA256,
                    bothRequestStatesRetired: true), encodedEvidence: bytes)
            })
    }
    func release() { reservation = nil; assets = nil; loaded = nil }
}
