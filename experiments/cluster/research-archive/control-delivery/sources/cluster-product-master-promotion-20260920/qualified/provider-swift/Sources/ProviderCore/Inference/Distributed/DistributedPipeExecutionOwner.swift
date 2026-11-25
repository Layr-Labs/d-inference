import Foundation
import MLXLMCommon
import DarkbloomClusterProtocol
import DarkbloomClusterProcess

/// Opt-in adapter only. No default factory or model-loading path installs it.
public final class DistributedPipeExecutionOwner: DistributedDeadlineExecutionOwner, @unchecked Sendable {
    private let pair: ClusterWorkerPair
    private let identity: DistributedResidentIdentity
    private let profile: DistributedResidentExecutionProfile
    private let chunkSize: Int

    public init(pair: ClusterWorkerPair, profile: DistributedResidentExecutionProfile, chunkSize: Int) throws {
        let wire = pair.profile
        let duration = profile.requestTimeout.components
        let nanoseconds = duration.seconds * 1_000_000_000 + duration.attoseconds / 1_000_000_000
        guard pair.readiness != nil, wire.id == profile.id, wire.vocabularySize == profile.vocabularySize,
              wire.maximumPromptTokens == profile.maxPromptTokens, wire.maximumOutputTokens == profile.maxOutputTokens,
              wire.maximumContextTokens == profile.maxContextTokens, (1...wire.maximumChunkTokens).contains(chunkSize),
              nanoseconds > 0, nanoseconds <= Int64(ClusterWorkerLimits.deadlineNanoseconds) else {
            throw DistributedEngineError.invalidConfiguration("worker profile or request deadline differs")
        }
        self.pair = pair; self.profile = profile; self.chunkSize = chunkSize
        let id = pair.identity
        identity = .init(membershipEpoch: id.membershipEpoch, modelID: id.modelID,
            artifactSHA256: id.artifactSHA256, configurationSHA256: id.configurationSHA256,
            peers: id.peers.map { .init(id: $0.id, buildSHA256: $0.buildSHA256) })
    }

    public func readiness() -> DistributedResidentReadiness? {
        guard let value = pair.readiness else { return nil }
        return .init(identity: identity, profileID: profile.id, requestCapacityBytes: value.requestCapacityBytes)
    }
    public func setReadinessInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        pair.setInvalidationHandler(handler)
    }
    public func projectFirstToken(_ request: CBv2Request, admission: CBv2FirstTokenDeadlineAdmission) -> CBv2FirstTokenProjectedWork {
        .unbounded // No measured peer transfer/control envelope is supplied by this adapter.
    }
    public func reserve(_ request: CBv2Request, identity expected: DistributedResidentIdentity,
                        profileID: String, capacityLimit: Int) throws -> any DistributedResidentRequestLease {
        // Compatibility for direct callers without an originating context.
        try reserve(request, identity: expected, profileID: profileID, capacityLimit: capacityLimit,
            deadlineContext: .init(generationDeadline: ContinuousClock.now.advanced(by: profile.requestTimeout)))
    }
    public func reserve(_ request: CBv2Request, identity expected: DistributedResidentIdentity,
                        profileID: String, capacityLimit: Int,
                        deadlineContext: DistributedRequestDeadlineContext) throws -> any DistributedResidentRequestLease {
        guard expected == identity, profileID == profile.id, readiness() != nil else { throw DistributedEngineError.unavailable }
        let p = request.sampling
        guard p.temperature == 0, p.topP == 1, p.topK == 0, p.minP == 0, p.repetitionPenalty == 1,
              p.frequencyPenalty == 0, p.presencePenalty == 0, p.seed == nil, p.logitBias.isEmpty, p.topLogprobs == 0,
              request.multimodal == nil, request.positionState == nil, request.tokenConstraint == nil,
              request.priority == 0, request.prefixCacheReceiptID == nil,
              request.stopStrings.count <= 16, request.stopStrings.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }) else {
            throw DistributedEngineError.unsupportedRequest("worker supports only greedy text; stop strings stay in the provider")
        }
        let uptime = DispatchTime.now().uptimeNanoseconds
        let deadlines = try deadlineContext.localDeadlines(at: ContinuousClock.now,
            uptimeBeforeNow: uptime, maximumRemaining: profile.requestTimeout,
            lifetimeDeadline: pair.localLifetimeDeadlineUptimeNanoseconds)
        let value = ClusterWorkerReservation(profileID: profileID, promptTokenIDs: request.promptTokens,
            stopTokenIDs: request.stopTokens.sorted(), outputCount: request.maxTokens, chunkSize: chunkSize,
            deadlineUptimeNanoseconds: deadlines.generation, capacityLimitBytes: capacityLimit)
        // CBv2 request IDs may be reused after retirement. Each native request
        // gets a fresh UUID; the lease retains its original public CBv2 identity.
        let native = try pair.reserve(requestID: UUID(), reservation: value, admissionDeadline: deadlines.admission)
        return DistributedPipeRequestLease(identity: identity, requestID: request.id, native: native)
    }
    public func shutdown() async { await pair.shutdown() }
}

private final class DistributedPipeRequestLease: DistributedResidentRequestLease, @unchecked Sendable {
    let identity: DistributedResidentIdentity
    let requestID: CBv2RequestID
    private let native: ClusterWorkerRequest
    var reservedBytes: Int { native.reservedBytes }
    var bytesInUse: Int { native.bytesInUse }
    init(identity: DistributedResidentIdentity, requestID: CBv2RequestID, native: ClusterWorkerRequest) {
        self.identity = identity; self.requestID = requestID; self.native = native
    }
    func start(emit: @escaping @Sendable (DistributedResidentEvent) -> Bool) throws {
        try native.start { event in
            switch event {
            case .token(let token): return emit(.token(token))
            case .finished(let reason): return emit(.finished(reason == .length ? .length : .stop))
            case .failed(let message): return emit(.finished(.error(message)))
            }
        }
    }
    func cancel() { native.cancel() }
    func waitUntilRetired() async { await native.waitUntilRetired() }
    func releaseResources() { native.releaseResources() }
}

#if NATIVE_PAIR_HARDWARE_EXPERIMENT
extension DistributedPipeRequestLease: DistributedResidentRequestProvenance {
    var nativeRequestID: UUID { native.requestID }
}
#endif
