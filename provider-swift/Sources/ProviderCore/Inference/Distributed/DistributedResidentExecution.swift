import DarkbloomClusterProtocol
import Foundation
import DarkbloomClusterProtocol
import MLXLMCommon

/// Experimental identity reported by an owner after both peer loads finish.
/// These are backend assertions, not remote attestation or hardware qualification.
public struct DistributedResidentIdentity: Sendable, Equatable {
    public struct Peer: Sendable, Equatable {
        public let id: String
        public let buildSHA256: String

        public init(id: String, buildSHA256: String) {
            self.id = id
            self.buildSHA256 = buildSHA256
        }
    }

    public let membershipEpoch: UUID
    public let modelID: String
    public let artifactSHA256: String
    public let configurationSHA256: String
    public let peers: [Peer]

    public init(
        membershipEpoch: UUID, modelID: String, artifactSHA256: String,
        configurationSHA256: String, peers: [Peer]
    ) {
        self.membershipEpoch = membershipEpoch
        self.modelID = modelID
        self.artifactSHA256 = artifactSHA256
        self.configurationSHA256 = configurationSHA256
        self.peers = peers
    }

    func validate() throws {
        func digest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
        }
        guard !modelID.isEmpty, modelID.utf8.count <= 512,
            digest(artifactSHA256), digest(configurationSHA256),
            peers.count == 2, peers[0].id != peers[1].id,
            peers.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 128 && digest($0.buildSHA256) })
        else { throw DistributedEngineError.invalidConfiguration("invalid two-peer identity") }
    }
}

/// Model-specific limits; the shared lifecycle does not assume a Qwen geometry.
public struct DistributedResidentExecutionProfile: Sendable {
    public let id: String
    public let vocabularySize: Int
    public let maxPromptTokens: Int
    public let maxOutputTokens: Int
    public let maxContextTokens: Int
    public let requestTimeout: Duration

    public init(
        id: String, vocabularySize: Int, maxPromptTokens: Int, maxOutputTokens: Int,
        maxContextTokens: Int, requestTimeout: Duration
    ) throws {
        guard !id.isEmpty, vocabularySize > 0, maxPromptTokens > 0, maxOutputTokens > 0,
            maxContextTokens >= maxPromptTokens, requestTimeout > .zero,
            requestTimeout <= .seconds(3600)
        else { throw DistributedEngineError.invalidConfiguration("invalid bounded execution profile") }
        self.id = id
        self.vocabularySize = vocabularySize
        self.maxPromptTokens = maxPromptTokens
        self.maxOutputTokens = maxOutputTokens
        self.maxContextTokens = maxContextTokens
        self.requestTimeout = requestTimeout
    }
}

public struct DistributedResidentReadiness: Sendable {
    public let identity: DistributedResidentIdentity
    public let profileID: String
    /// The owner's conservative request-state budget, not the sum of peer RAM.
    public let requestCapacityBytes: Int
    /// The longest context (prompt plus output) the owner serves now: for a
    /// pair, what both ranks' host memory gates admit with their weights
    /// resident, re-derived while idle. Nil when the owner states none (the
    /// profile's maximum applies). A longer request is refused before admission.
    public let servingContextTokens: Int?
    /// The media contract both ranks serve (`ClusterGLMMedia.contract` for GLM
    /// images and video on the tensor-parallel pair); nil serves text only.
    public let media: String?

    public init(identity: DistributedResidentIdentity, profileID: String, requestCapacityBytes: Int,
                servingContextTokens: Int? = nil, media: String? = nil) {
        self.identity = identity
        self.profileID = profileID
        self.requestCapacityBytes = requestCapacityBytes
        self.servingContextTokens = servingContextTokens
        self.media = media
    }
}

public enum DistributedResidentEvent: Sendable {
    /// One target-authoritative committed token. Draft/MTP tokens are not accepted.
    case token(Int)
    /// A committed token with the decoding rank's raw logprobs for it, for a
    /// request that asks for them (`CBv2SamplingParams.topLogprobs`).
    case loggedToken(Int, CBv2TokenLogprob)
    case finished(CBv2FinishReason)
    /// Both peers restored `reused` prompt tokens from their rank-local prefix
    /// caches and both now hold `stored` prompt frontiers. Once, before the
    /// finish, only when either is not empty.
    case promptCache(reused: Int, stored: [Int])
    /// What the ranks measured of the request (hand-off, MTP acceptance).
    /// Once, before the finish, only when either rank sent any.
    case telemetry(DistributedRankTelemetry)
}

extension DistributedResidentEvent {
    /// The committed token this event carries, with or without logprobs.
    var committedToken: Int? {
        switch self {
        case .token(let token), .loggedToken(let token, _): token
        case .finished, .promptCache, .telemetry: nil
        }
    }
}

/// Both ranks' own measurements of one request (PROD-PLAN S24). Values only.
public struct DistributedRankTelemetry: Sendable, Equatable {
    /// The slower rank's hand-off wall time, in milliseconds.
    public let handoffMilliseconds: Double?
    public let handoffBytes: Int?
    /// The decoding rank's MTP drafts and acceptances, summed over the ranks that drafted.
    public let mtpDrafted: Int?
    public let mtpAccepted: Int?
    /// The decoding rank's MTP rounds, summed over the ranks that reported them.
    public let mtpRounds: Int?

    public init(handoffMilliseconds: Double?, handoffBytes: Int?, mtpDrafted: Int?, mtpAccepted: Int?,
                mtpRounds: Int? = nil) {
        self.handoffMilliseconds = handoffMilliseconds; self.handoffBytes = handoffBytes
        self.mtpDrafted = mtpDrafted; self.mtpAccepted = mtpAccepted; self.mtpRounds = mtpRounds
    }

    /// Merges what each rank sent: the longer hand-off (both ranks wait for it),
    /// the larger byte count, and the MTP counts of whichever ranks drafted.
    public init(rank0: ClusterWorkerRequestTelemetry?, rank1: ClusterWorkerRequestTelemetry?) {
        let ranks = [rank0, rank1].compactMap { $0 }
        let handoff = ranks.compactMap(\.handoffNanoseconds).max()
        handoffMilliseconds = handoff.map { (Double($0) / 1e4).rounded() / 100 }
        handoffBytes = ranks.compactMap(\.handoffBytes).max()
        let drafted = ranks.compactMap(\.mtpDrafted), accepted = ranks.compactMap(\.mtpAccepted)
        mtpDrafted = drafted.isEmpty ? nil : drafted.reduce(0, +)
        mtpAccepted = accepted.isEmpty ? nil : accepted.reduce(0, +)
        let rounds = ranks.compactMap(\.mtpRounds)
        mtpRounds = rounds.isEmpty ? nil : rounds.reduce(0, +)
    }
}

/// A single request's resource ownership, including both peers' request state.
/// All synchronous methods must return promptly, be thread-safe and permit an
/// event callback to call cancel(). Never hold a non-reentrant lock across emit.
public protocol DistributedResidentRequestLease: AnyObject, Sendable {
    var identity: DistributedResidentIdentity { get }
    var requestID: CBv2RequestID { get }
    var reservedBytes: Int { get }
    var bytesInUse: Int { get }

    /// Start at most once. False from emit means no next token may be sent.
    /// Unless cancel() was called, perform a clean stop/length/client-stop
    /// handshake and acknowledge both peers' retirement. Do not turn normal
    /// callback completion into the native session's failed-cancellation path.
    /// The callback serializes one token at a time; start itself must not wait for inference.
    func start(emit: @escaping @Sendable (DistributedResidentEvent) -> Bool) throws
    /// Abnormal termination (deadline, output/peer failure, or a caller whose
    /// request for a clean stop was refused or did not finish in time).
    /// This is separate from a normal false return from emit.
    func cancel()
    /// The consumer went away, or the host is stopping: end the request at its
    /// next committed token with the clean client-stop handshake, so that both
    /// peers retire and the owner stays usable for the next request. True when
    /// the lease accepted; retirement then follows without `cancel()`, at the
    /// first token for a request that has produced none yet. False when this
    /// lease cannot stop that way, and the caller falls back to `cancel()`.
    /// Sets no time limit of its own.
    func requestCleanStop() -> Bool
    /// Return only after both peers acknowledge retirement or are fenced by the
    /// owner. A lost peer, elapsed timer, or sent cancel is not acknowledgement.
    /// This must also work for a reservation cancelled before start().
    func waitUntilRetired() async
    /// Called exactly once after waitUntilRetired, never on a timeout alone.
    func releaseResources()
    /// Which way this request was routed, when the owner routes requests.
    var route: DistributedRequestRouteNote? { get }
}

public extension DistributedResidentRequestLease {
    /// An owner without a clean stop of its own: every caller stop is `cancel()`.
    func requestCleanStop() -> Bool { false }
    /// An owner without per-request routes: every request runs as placed.
    var route: DistributedRequestRouteNote? { nil }
}

/// Which way one request went (`ClusterRequestRouter`), as its telemetry and
/// `darkbloom cluster status` name it: `pair`, or `alone:<member>` when the
/// member holding the whole model served it by itself, and why.
public struct DistributedRequestRouteNote: Sendable, Equatable {
    public let label: String
    public let reason: String
    public init(label: String, reason: String) { self.label = label; self.reason = reason }
}

/// Injectable, exclusive resident owner. No live Qwen backend is attached here.
public protocol DistributedResidentExecutionOwner: AnyObject, Sendable {
    /// Nil until both peers have loaded and while either peer is unavailable.
    func readiness() -> DistributedResidentReadiness?
    /// Install one observer. Notify every loss/replacement of either loaded peer.
    func setReadinessInvalidationHandler(_ handler: @escaping @Sendable () -> Void)
    /// Must honor admission's phase-rate policy and include transfer/control
    /// costs. Unknown costs return .unbounded; local compute alone is insufficient.
    func projectFirstToken(
        _ request: CBv2Request, admission: CBv2FirstTokenDeadlineAdmission
    ) -> CBv2FirstTokenProjectedWork
    /// Atomically revalidate identity/profile and actual per-peer resources.
    /// This acquires ownership but does not start model work. Throwing must leave
    /// no reservation behind. capacityLimit is an additional provider ceiling.
    func reserve(
        _ request: CBv2Request, identity: DistributedResidentIdentity,
        profileID: String, capacityLimit: Int
    ) throws -> any DistributedResidentRequestLease
    /// Release resident models only after all request leases are retired/released.
    func shutdown() async
    /// Requests the owner serves at once (the pair's batch lanes). One for
    /// every owner that serves one request at a time.
    var concurrentRequests: Int { get }
}

extension DistributedResidentExecutionOwner {
    public var concurrentRequests: Int { 1 }
}

/// Optional capability for owners whose admission performs bounded IO. Legacy
/// injected owners retain the old reserve API; the engine still enforces its own
/// deadlines, but only a deadline-aware owner can bound synchronous reserve waits.
public protocol DistributedDeadlineExecutionOwner: DistributedResidentExecutionOwner {
    func reserve(
        _ request: CBv2Request, identity: DistributedResidentIdentity,
        profileID: String, capacityLimit: Int,
        deadlineContext: DistributedRequestDeadlineContext
    ) throws -> any DistributedResidentRequestLease
}

public enum DistributedEngineError: Error, Sendable, Equatable {
    case invalidConfiguration(String)
    /// A request this pair can never serve as asked. Deterministic for the
    /// request and the loaded model: the client is told why with a 4xx.
    case refused(DistributedRequestRefusal)
    case unavailable
    case shuttingDown
    /// This request alone was refused before it started, for capacity: it is
    /// longer than the owner's serving context now, or a rank's host memory
    /// gate refused its reservation (and the other rank gave its back). The
    /// owner keeps serving; the client gets a retryable capacity status.
    case refusedForCapacity(requestedContextTokens: Int, servingContextTokens: Int, reason: String)
}

/// Why a request was refused before it reached the pair. A closed set: the
/// text names the rule and the model's own limits, never request content, so
/// it may be returned to the client as is.
public enum DistributedRequestRefusal: String, Sendable, Equatable, CaseIterable {
    case emptyPrompt = "empty_prompt"
    case promptTooLong = "prompt_too_long"
    case invalidMaxTokens = "invalid_max_tokens"
    case outputTooLong = "output_too_long"
    case contextTooLong = "context_too_long"
    case tokenOutsideVocabulary = "token_outside_vocabulary"
    case logprobsUnsupported = "logprobs_unsupported"
    case constrainedDecodingUnsupported = "constrained_decoding_unsupported"
    case mediaUnsupported = "media_unsupported"
    case priorityUnsupported = "priority_unsupported"
    case invalidStopSequences = "invalid_stop_sequences"
    case invalidSampling = "invalid_sampling"
    case tooManyLogitBiasEntries = "too_many_logit_bias_entries"

    /// The prompt or output does not fit the model's limits on the pair:
    /// the coordinator classifies these as exceeding context.
    public var exceedsContext: Bool {
        [.promptTooLong, .outputTooLong, .contextTooLong].contains(self)
    }

    /// The client-facing text. With the profile it names the model's limits.
    public func message(_ profile: DistributedResidentExecutionProfile?) -> String {
        func limit(_ value: Int?) -> String { value.map { " of \($0) tokens" } ?? "" }
        switch self {
        case .emptyPrompt: return "The prompt is empty."
        case .promptTooLong:
            return "The prompt is longer than this model's limit\(limit(profile?.maxPromptTokens)) on this cluster."
        case .invalidMaxTokens: return "max_tokens must be at least 1."
        case .outputTooLong:
            return "max_tokens is above this model's output limit\(limit(profile?.maxOutputTokens)) on this cluster."
        case .contextTooLong:
            return "The prompt plus max_tokens is above this model's context\(limit(profile?.maxContextTokens)) on this cluster."
        case .tokenOutsideVocabulary: return "A token is outside this model's vocabulary."
        case .logprobsUnsupported:
            return "top_logprobs is above this cluster's limit of \(ClusterWorkerSampling.maximumTopLogprobs)."
        case .constrainedDecodingUnsupported: return "Constrained decoding is not supported for this model on this cluster."
        case .mediaUnsupported: return "Media input is not supported on this cluster."
        case .priorityUnsupported: return "Request priority is not supported on this cluster."
        case .invalidStopSequences: return "Stop sequences must be at most 16, each non-empty and at most 1,024 bytes."
        case .invalidSampling: return "A sampling parameter is not a finite number."
        case .tooManyLogitBiasEntries:
            return "logit_bias has more than \(ClusterWorkerSampling.maximumLogitBiasEntries) entries."
        }
    }
}

extension DistributedResidentExecutionProfile {
    /// The first rule a request breaks on this pair, or nil when the pair can
    /// serve it. The engine refuses with it before any reservation; the owner
    /// checks it again before anything reaches a worker.
    func refusal(for request: CBv2Request) -> DistributedRequestRefusal? {
        let p = request.sampling
        if request.multimodal != nil || request.positionState != nil { return .mediaUnsupported }
        if let wire = request.clusterStillImages {
            guard request.mimoClusterImages == nil, id == ClusterStillImages.glmProfileID,
                  let media = try? ClusterStillImages.decodeBounded(wire),
                  (try? media.validateStructure(promptCount: request.promptTokens.count)) != nil else { return .mediaUnsupported }
        }
        if let wire = request.clusterGLMMedia {
            // GLM images and video on the tensor-parallel pair: the text row's
            // profile, the envelope alone, bound to this prompt's spans.
            guard request.clusterStillImages == nil, request.mimoClusterImages == nil,
                  id == ClusterGLMImageCandidate.textProfileID,
                  let media = try? ClusterGLMMedia.decodeBounded(wire),
                  media.featureTokens < request.promptTokens.count else { return .mediaUnsupported }
        }
        if let wire = request.mimoClusterImages {
            guard id == "registered_mimo_v26_flash_mopd_greedy_generation_v1" + ClusterMiMoImages.profileSuffix,
                  let images = try? ClusterMiMoImages.decodeBounded(wire),
                  (try? images.validate(prompt:request.promptTokens)) != nil else { return .mediaUnsupported }
        }
        if request.tokenConstraint != nil { return .constrainedDecodingUnsupported }
        // The decoding rank gathers them as the product does; a runtime that
        // cannot refuses the request alone (unsupported, retryable).
        if !(0...ClusterWorkerSampling.maximumTopLogprobs).contains(p.topLogprobs) { return .logprobsUnsupported }
        if request.priority != 0 { return .priorityUnsupported }
        if request.promptTokens.isEmpty { return .emptyPrompt }
        if request.promptTokens.count > maxPromptTokens { return .promptTooLong }
        if request.maxTokens <= 0 { return .invalidMaxTokens }
        if request.maxTokens > maxOutputTokens { return .outputTooLong }
        let total = request.promptTokens.count.addingReportingOverflow(request.maxTokens)
        if total.overflow || total.partialValue > maxContextTokens { return .contextTooLong }
        if !request.promptTokens.allSatisfy({ 0 <= $0 && $0 < vocabularySize })
            || !request.stopTokens.allSatisfy({ 0 <= $0 && $0 < vocabularySize }) {
            return .tokenOutsideVocabulary
        }
        if request.stopStrings.count > 16 || !request.stopStrings.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }) {
            return .invalidStopSequences
        }
        let values = [p.temperature, p.topP, p.minP, p.repetitionPenalty, p.frequencyPenalty, p.presencePenalty]
        if !values.allSatisfy(\.isFinite) || !p.logitBias.values.allSatisfy(\.isFinite) { return .invalidSampling }
        if DistributedSampling.logitBias(p.logitBias, vocabularySize: vocabularySize).count
            > ClusterWorkerSampling.maximumLogitBiasEntries {
            return .tooManyLogitBiasEntries
        }
        return nil
    }
}

/// The worker's view of a request's sampling, resolved as the single-Mac
/// product resolves it.
enum DistributedSampling {
    /// Entries for tokens outside the vocabulary have no effect in the
    /// product's sampler and are dropped here; the rest ascend by token.
    static func logitBias(_ bias: [Int: Float], vocabularySize: Int) -> [ClusterWorkerSampling.LogitBias] {
        bias.filter { 0 <= $0.key && $0.key < vocabularySize }.sorted { $0.key < $1.key }
            .map { .init(tokenID: $0.key, bias: $0.value) }
    }

    /// Nil for greedy text with no transform: the reservation then carries no
    /// sampling and the worker selects the argmax as it always has. Otherwise
    /// the request's values; its seed must already be resolved (the engine
    /// gives an omitted seed its own fallback, as the product's engine does),
    /// and the stream is the request's product identity.
    static func wire(for request: CBv2Request, vocabularySize: Int) -> ClusterWorkerSampling? {
        let p = request.sampling
        let value = ClusterWorkerSampling(temperature: p.temperature, topP: p.topP,
            // The product applies top-k only below the vocabulary.
            topK: p.topK > 0 && p.topK < vocabularySize ? p.topK : 0, minP: p.minP,
            repetitionPenalty: p.repetitionPenalty,
            repetitionContextSize: min(max(0, p.repetitionContextSize), ClusterWorkerLimits.contextTokens),
            frequencyPenalty: p.frequencyPenalty, presencePenalty: p.presencePenalty,
            seed: p.seed ?? 0, stream: request.id.raw,
            logitBias: logitBias(p.logitBias, vocabularySize: vocabularySize), topLogprobs: p.topLogprobs)
        return value.isGreedyNoOp ? nil : value
    }
}
