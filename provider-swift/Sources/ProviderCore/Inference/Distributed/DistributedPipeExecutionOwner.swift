import Foundation
import MLXLMCommon
import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import DarkbloomClusterProcess

/// Opt-in adapter only. No default factory or model-loading path installs it.
public final class DistributedPipeExecutionOwner: DistributedDeadlineExecutionOwner, @unchecked Sendable {
    private let pair: ClusterWorkerPair
    private let identity: DistributedResidentIdentity
    private let profile: DistributedResidentExecutionProfile
    private let chunkSize: Int
    /// Per-request route between the pair as placed and the member holding
    /// the whole model alone (`ClusterRequestRoutingBasis`); nil routes nothing.
    private let routing: ClusterRequestRouting?

    public init(pair: ClusterWorkerPair, profile: DistributedResidentExecutionProfile, chunkSize: Int,
                routing: ClusterRequestRouting? = nil) throws {
        let wire = pair.profile
        let duration = profile.requestTimeout.components
        let nanoseconds = duration.seconds * 1_000_000_000 + duration.attoseconds / 1_000_000_000
        guard pair.readiness != nil, wire.id == profile.id, wire.vocabularySize == profile.vocabularySize,
              wire.maximumPromptTokens == profile.maxPromptTokens, wire.maximumOutputTokens == profile.maxOutputTokens,
              wire.maximumContextTokens == profile.maxContextTokens, (1...wire.maximumChunkTokens).contains(chunkSize),
              nanoseconds > 0, nanoseconds <= Int64(ClusterWorkerLimits.deadlineNanoseconds) else {
            throw DistributedEngineError.invalidConfiguration("worker profile or request deadline differs")
        }
        self.pair = pair; self.profile = profile; self.chunkSize = chunkSize; self.routing = routing
        let id = pair.identity
        identity = .init(membershipEpoch: id.membershipEpoch, modelID: id.modelID,
            artifactSHA256: id.artifactSHA256, configurationSHA256: id.configurationSHA256,
            peers: id.peers.map { .init(id: $0.id, buildSHA256: $0.buildSHA256) })
    }

    public func readiness() -> DistributedResidentReadiness? {
        guard let value = pair.readiness else { return nil }
        return .init(identity: identity, profileID: profile.id, requestCapacityBytes: value.requestCapacityBytes,
            servingContextTokens: value.servingContextTokens, media: value.media)
    }
    public func setReadinessInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        pair.setInvalidationHandler(handler)
    }
    public func projectFirstToken(_ request: CBv2Request, admission: CBv2FirstTokenDeadlineAdmission) -> CBv2FirstTokenProjectedWork {
        .unbounded(reason: nil) // No measured peer transfer/control envelope is supplied by this adapter.
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
        // Stop strings stay in the provider. Sampling goes to the decoding
        // rank; a stochastic request carries its resolved seed.
        if let refusal = profile.refusal(for: request) { throw DistributedEngineError.refused(refusal) }
        let sampling = DistributedSampling.wire(for: request, vocabularySize: profile.vocabularySize)
        guard sampling == nil || request.sampling.seed != nil else { throw DistributedEngineError.refused(.invalidSampling) }
        let uptime = DispatchTime.now().uptimeNanoseconds
        // The workers have no lifetime: their rank leases are renewed while
        // the request runs, so only the request's own budget bounds it.
        let deadlines = try deadlineContext.localDeadlines(at: ContinuousClock.now,
            uptimeBeforeNow: uptime, maximumRemaining: profile.requestTimeout,
            lifetimeDeadline: .max)
        // The faster way for this request: the pair is chosen only when it is
        // predicted faster than the member alone beyond the tie tolerance, so
        // a strong Mac is never made slower by its pair. Both are qualified.
        let decided = routing?.route(promptTokens: request.promptTokens.count, maximumOutputTokens: request.maxTokens)
        let route = decided.map { value in
            let served = value.pairBasis == .served || value.aloneBasis == .served
            // Without a measured speed for every Mac and no served route, times are the speed index's relative units.
            let unit = served || routing?.setup.devices.allSatisfy(\.speed.absolute) == true ? " s" : " index units"
            return DistributedRequestRouteNote(label: value.label, reason: value.reason + String(format: " (pair %.2f%@, alone %@; %@)",
                value.pairSeconds, unit, value.aloneSeconds.map { String(format: "%.2f", $0) + unit } ?? "-",
                served ? "corrected by this pair's speed records" : "predicted from the plan"))
        }
        let stillImages = try request.clusterStillImages.map { try ClusterStillImages.decodeBounded($0) }
        guard stillImages == nil || (identity.modelID == "registered_glm53_flash"
            && stillImages?.configurationSHA256 == identity.configurationSHA256) else {
            throw DistributedEngineError.refused(.mediaUnsupported)
        }
        let media = try request.mimoClusterImages.map { try ClusterMiMoImages.decodeBounded($0) }
        guard media == nil || (identity.modelID == "registered_mimo_v26_flash_mopd"
            && identity.artifactSHA256 == "2334547d8acc9898ad4a74570ce44d2b12390bbac8d4bc52c092eb5ad5cfe034") else {
            throw DistributedEngineError.refused(.mediaUnsupported)
        }
        // GLM images and video on the tensor-parallel pair: only when both ranks
        // serve the media contract, for the model and configuration they loaded.
        let glmMedia = try request.clusterGLMMedia.map { try ClusterGLMMedia.decodeBounded($0) }
        guard glmMedia == nil || (identity.modelID == ClusterGLMImageCandidate.runtimeModelID
            && glmMedia?.configurationSHA256 == identity.configurationSHA256
            && glmMedia?.carriesEncodedBytes == true && stillImages == nil && media == nil
            && pair.readiness?.media == ClusterGLMMedia.contract) else {
            throw DistributedEngineError.refused(.mediaUnsupported)
        }
        let value = ClusterWorkerReservation(profileID: profileID, promptTokenIDs: request.promptTokens,
            stopTokenIDs: request.stopTokens.sorted(), outputCount: request.maxTokens, chunkSize: chunkSize,
            deadlineUptimeNanoseconds: deadlines.generation, capacityLimitBytes: capacityLimit, sampling: sampling,
            route: media == nil && stillImages == nil && glmMedia == nil ? decided?.workerRoute : nil,
            mimoImages:media, stillImages:stillImages, glmMedia: glmMedia)
        // Encode the COMPLETE bounded command before sending either rank.
        // Use largest legal sequence metadata so a later pipe header cannot
        // exceed the command bound (a GLM media reservation's own bound)
        // after rank 0 has already reserved.
        _ = try ClusterWorkerCodec.encode(.init(membershipEpoch:identity.membershipEpoch,
            sequence:UInt64(Int64.max)-1,requestID:UUID(),command:.reserve(value)))
        // CBv2 request IDs may be reused after retirement. Each native request
        // gets a fresh UUID; the lease retains its original public CBv2 identity.
        let native: ClusterWorkerRequest
        do {
            native = try pair.reserve(requestID: UUID(), reservation: value, admissionDeadline: deadlines.admission)
        } catch ClusterWorkerOwnerError.refused(let reason) {
            // This request alone; the pair is idle and serving. Its reason and
            // the context the pair serves now reach the client (503).
            throw DistributedEngineError.refusedForCapacity(
                requestedContextTokens: request.promptTokens.count + request.maxTokens,
                servingContextTokens: pair.servingContextTokens, reason: reason.rawValue)
        }
        return DistributedPipeRequestLease(identity: identity, requestID: request.id, native: native, route: route)
    }
    public func shutdown() async { await pair.shutdown() }
    /// The pair's batch lanes (continuous batching on the pair).
    public var concurrentRequests: Int { pair.lanes }
}

private final class DistributedPipeRequestLease: DistributedResidentRequestLease, @unchecked Sendable {
    /// Whether the consumer ended the request: it declined a token, or it asked
    /// for the clean stop itself.
    private final class ConsumerStop: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var requested: Bool { lock.withLock { value } }
        func record() { lock.withLock { value = true } }
    }
    let identity: DistributedResidentIdentity
    let requestID: CBv2RequestID
    private let native: ClusterWorkerRequest
    private let consumerStop = ConsumerStop()
    let route: DistributedRequestRouteNote?
    var reservedBytes: Int { native.reservedBytes }
    var bytesInUse: Int { native.bytesInUse }
    init(identity: DistributedResidentIdentity, requestID: CBv2RequestID, native: ClusterWorkerRequest,
         route: DistributedRequestRouteNote? = nil) {
        self.identity = identity; self.requestID = requestID; self.native = native; self.route = route
    }
    func start(emit: @escaping @Sendable (DistributedResidentEvent) -> Bool) throws {
        try native.start { [consumerStop] event in
            switch event {
            case .token(let token, let logprobs):
                let more = emit(logprobs.map { .loggedToken(token, Self.logprob(token, $0)) } ?? .token(token))
                if !more { consumerStop.record() }
                return more
            case .finished(let reason):
                // A client stop the consumer did not ask for was requested by
                // the pair's owner, which is stopping: the output is incomplete
                // and is not reported as a natural stop.
                if reason == .clientStop, !consumerStop.requested { return emit(.finished(.cancelled)) }
                return emit(.finished(reason == .length ? .length : .stop))
            case .failed(let message): return emit(.finished(.error(message)))
            case .promptCache(let reused, let stored): return emit(.promptCache(reused: reused, stored: stored))
            case .telemetry(let rank0, let rank1): return emit(.telemetry(.init(rank0: rank0, rank1: rank1)))
            }
        }
    }
    /// The rank's logprobs in the product's engine shape.
    static func logprob(_ token: Int, _ value: ClusterWorkerTokenLogprobs) -> CBv2TokenLogprob {
        CBv2TokenLogprob(token: token, logprob: value.logprob,
            topLogprobs: value.top.map { (token: $0.tokenID, logprob: $0.logprob) })
    }
    func cancel() { native.cancel() }
    func requestCleanStop() -> Bool {
        guard native.requestCleanStop() else { return false }
        consumerStop.record(); return true
    }
    func waitUntilRetired() async { await native.waitUntilRetired() }
    func releaseResources() { native.releaseResources() }
}
