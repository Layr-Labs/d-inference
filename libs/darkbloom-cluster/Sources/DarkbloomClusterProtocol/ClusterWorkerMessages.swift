import Foundation

public enum ClusterWorkerProtocolError: Error, Equatable, Sendable {
    case invalid(String)
}

/// Software ceilings, never permission to allocate native state or load a model.
public enum ClusterWorkerLimits {
    /// 2: a reservation's prompt crosses as packed little-endian UInt32 token
    /// IDs in base64 (`promptTokens`, with `promptTokenCount`) instead of a
    /// JSON number array. Every record carries the version and every reader
    /// refuses another, and the runtime capability carries it too, so
    /// mismatched builds refuse at pairing and setup, never inside a request.
    public static let version = 2
    /// A reservation carries its whole prompt as packed token IDs (four bytes
    /// each, 5 1/3 in base64): 8 MiB holds a `wirePromptTokens` prompt with its
    /// stop tokens, sampling and routes.
    public static let commandBytes = 8 * 1024 * 1024
    /// The one larger command: a reservation carrying GLM media bytes to the
    /// rank on the leader's own Mac (`ClusterGLMMedia`). Every other command,
    /// and every record that crosses the link, stays within `commandBytes`.
    public static let mediaCommandBytes = commandBytes + ClusterGLMMedia.maximumEnvelopeBytes
    /// One command inside its owner envelope (`ClusterOwnerWire`) or as a pipe
    /// record: the largest command and room for the envelope's own fields.
    /// Every hop a command takes admits this, so a command the codec admits
    /// is never refused on its way to a rank.
    public static let envelopeBytes = mediaCommandBytes + 64 * 1024
    /// What one rank's command queue holds (`ClusterWorkerProcess`,
    /// `ClusterRemoteWorkerEndpoint`): the largest command and 1 MiB of other
    /// commands beside it. A queue that cannot take a reservation now refuses
    /// that request alone (`ClusterWorkerOwnerError.refused(.busy)`).
    public static let queuedCommandBytes = mediaCommandBytes + 1024 * 1024
    public static let eventBytes = 16 * 1024
    /// The standard request bounds: what every family is sized and qualified
    /// for unless its own registered row declares more (`wire*`). A family's
    /// limits and memory plan use these; a registered row with a longer native
    /// context names its own within the wire bounds.
    public static let promptTokens = 32_768
    public static let outputTokens = 32_768
    // Leave room for the full prompt budget as well as a 32K completion.
    public static let contextTokens = promptTokens + outputTokens
    /// What the wire carries and validates: the longest native context a
    /// registered model declares (GLM-5.3-Flash, `max_position_embeddings`
    /// 1,048,576) and the longest output a provider lists for one (Z.AI lists
    /// 131,072 for GLM-5.3-Flash). Each profile names its own limits within
    /// these; a request is held to its profile, and each rank's live memory
    /// gate decides whether it fits.
    public static let wireContextTokens = 1_048_576
    public static let wirePromptTokens = wireContextTokens
    public static let wireOutputTokens = 131_072
    public static let stopTokens = 256
    public static let vocabularySize = 262_144
    public static let deadlineNanoseconds: UInt64 = 3_600_000_000_000
    public static let capacityBytes = 1 << 50
    /// How many recent request IDs a session remembers in order to refuse a
    /// replayed one. A window, never a cap: a session serves any number of
    /// requests for as long as its owner keeps it.
    public static let requestReplayWindow = 4096
    /// Keep-warm ordinals are positive and below this.
    public static let keepWarmOrdinals = Int(Int32.max)
}

/// The rank lease between a worker's owner and the worker (S03). A worker has
/// no fixed lifetime: it is armed at launch, before any weights load, with a
/// deadline at most `maximumNanoseconds` away, and its owner renews it every
/// `renewNanoseconds` with an `extendDeadline` line that moves the deadline to
/// `ttlNanoseconds` after the line arrives. An owner that stops renewing (it
/// stopped, died, or lost its link) leaves the worker to end by itself within
/// the time to live, through the process's one forced exit, which releases
/// MLX's wired memory first. Renewals travel on the worker's control pipe,
/// never on the data plane.
public enum ClusterWorkerLease {
    public static let renewNanoseconds: UInt64 = 5_000_000_000
    public static let ttlNanoseconds: UInt64 = 30_000_000_000
    /// The longest a launch deadline or one renewal may grant.
    public static let maximumNanoseconds: UInt64 = 120_000_000_000
}

/// One renewal of the rank lease: the deadline moves to `ttlNanoseconds` after
/// the worker reads it. `renewal` counts up from 1 and is for the log only.
public struct ClusterWorkerLeaseRenewal: Equatable, Sendable {
    public let membershipEpoch: UUID
    public let renewal: UInt64
    public let ttlNanoseconds: UInt64
    public init(membershipEpoch: UUID, renewal: UInt64, ttlNanoseconds: UInt64 = ClusterWorkerLease.ttlNanoseconds) throws {
        try workerRequire(renewal > 0 && renewal < UInt64(Int64.max)
            && (1...ClusterWorkerLease.maximumNanoseconds).contains(ttlNanoseconds), "Invalid lease renewal")
        self.membershipEpoch = membershipEpoch; self.renewal = renewal; self.ttlNanoseconds = ttlNanoseconds
    }
}

/// A line on the worker's control pipe: a sequenced request command, or a
/// rank-lease renewal, which is outside the request sequence.
public enum ClusterWorkerControlLine: Equatable, Sendable {
    case command(ClusterWorkerCommandFrame)
    case extendDeadline(ClusterWorkerLeaseRenewal)
}

public struct ClusterWorkerPeer: Equatable, Sendable {
    public let id: String
    public let buildSHA256: String
    public init(id: String, buildSHA256: String) { self.id = id; self.buildSHA256 = buildSHA256 }
}

/// Backend assertions for an already configured membership, not attestation.
public struct ClusterWorkerIdentity: Equatable, Sendable {
    public let membershipEpoch: UUID
    public let modelID: String
    public let artifactSHA256: String
    public let configurationSHA256: String
    public let peers: [ClusterWorkerPeer]
    public init(membershipEpoch: UUID, modelID: String, artifactSHA256: String,
                configurationSHA256: String, peers: [ClusterWorkerPeer]) {
        self.membershipEpoch = membershipEpoch; self.modelID = modelID
        self.artifactSHA256 = artifactSHA256; self.configurationSHA256 = configurationSHA256
        self.peers = peers
    }
}

public struct ClusterWorkerProfile: Equatable, Sendable {
    public let id: String
    public let vocabularySize: Int
    public let maximumPromptTokens: Int
    public let maximumOutputTokens: Int
    public let maximumChunkTokens: Int
    public let maximumContextTokens: Int
    public init(id: String, vocabularySize: Int, maximumPromptTokens: Int, maximumOutputTokens: Int,
                maximumChunkTokens: Int, maximumContextTokens: Int) {
        self.id = id; self.vocabularySize = vocabularySize
        self.maximumPromptTokens = maximumPromptTokens; self.maximumOutputTokens = maximumOutputTokens
        self.maximumChunkTokens = maximumChunkTokens; self.maximumContextTokens = maximumContextTokens
    }
}

/// The data-plane credential of one worker (S16): its per-epoch signing key,
/// its member's certificate over that key, its member's identity and the
/// identity it pins for its peer (P-256: 32-byte private key, 64-byte raw
/// signature, 65-byte X9.63 public keys). The owner writes it once, as the
/// first line of the worker's control pipe, before any other line; it never
/// appears on a command line, in the environment or in a log.
public struct ClusterWorkerDataPlaneTrust: Equatable, Sendable {
    public let membershipEpoch: UUID
    public let rank: Int
    public let workerSigningKey: Data
    public let workerCertificate: Data
    public let memberIdentity: Data
    public let peerPin: Data
    public init(membershipEpoch: UUID, rank: Int, workerSigningKey: Data, workerCertificate: Data,
                memberIdentity: Data, peerPin: Data) throws {
        try workerRequire((0...1).contains(rank) && workerSigningKey.count == 32 && workerCertificate.count == 64
            && memberIdentity.count == 65 && peerPin.count == 65 && memberIdentity != peerPin,
            "Invalid data-plane credential")
        self.membershipEpoch = membershipEpoch; self.rank = rank; self.workerSigningKey = workerSigningKey
        self.workerCertificate = workerCertificate; self.memberIdentity = memberIdentity; self.peerPin = peerPin
    }
    /// What `--data-plane` names on the worker's command line.
    public static let argument = "encrypted_v1"
}

/// The key of one worker's prompt-prefix SSD tier: 32 bytes its owner derived
/// for this Mac (from the product's Secure Enclave-rooted key, or its owner-only
/// key file), bound to the worker's epoch and rank. The owner writes it once, as
/// a line of the worker's control pipe right after the data-plane credential
/// (first when there is none) and before any other line; the worker announced
/// by `--prefix-ssd-key` with `argument` reads it there. Like the credential it
/// never appears on a command line, in the environment or in a log: an
/// environment is readable by every process of the same user for the
/// process's whole life. Its descriptions redact the key.
public struct ClusterWorkerPrefixSSDKey: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let membershipEpoch: UUID
    public let rank: Int
    public let key: Data
    public init(membershipEpoch: UUID, rank: Int, key: Data) throws {
        try workerRequire((0...1).contains(rank) && key.count == 32, "Invalid prefix-SSD key")
        self.membershipEpoch = membershipEpoch; self.rank = rank; self.key = key
    }
    /// What `--prefix-ssd-key` names on the worker's command line: the scheme,
    /// never the key. A worker built with this delivery carries these bytes,
    /// which is how an owner tells it from one that does not.
    public static let argument = "darkbloom/prefix-ssd-key/input-line/v1"
    /// The environment names an older owner put the key (or its file) in. A
    /// worker refuses to start when either is present, so a mismatched pair of
    /// binaries fails loudly instead of the key sitting in an environment.
    public static let retiredEnvironmentNames = ["DARKBLOOM_CLUSTER_PREFIX_SSD_KEY", "DARKBLOOM_CLUSTER_PREFIX_SSD_KEY_FILE"]
    public var description: String {
        "ClusterWorkerPrefixSSDKey(epoch: \(membershipEpoch.uuidString.lowercased()), rank: \(rank), key: <redacted>)"
    }
    public var debugDescription: String { description }
}

/// What a ready worker states about its data plane. Both ranks of one keyed
/// session report the same transcript and edge; an owner compares them.
public struct ClusterWorkerDataPlane: Equatable, Sendable {
    public static let encrypted = "encrypted_v1"
    /// `encrypted_v1`: every transfer between the ranks is an authenticated,
    /// encrypted record (AES-256-GCM, directional keys, rekeyed by count,
    /// bytes and age). The only value a worker reports.
    public let protection: String
    /// The peer's hello verified against the identity this worker pins.
    public let peerVerified: Bool
    public let transcriptSHA256: String
    public let edgeID: String
    public init(protection: String, peerVerified: Bool, transcriptSHA256: String, edgeID: String) {
        self.protection = protection; self.peerVerified = peerVerified
        self.transcriptSHA256 = transcriptSHA256; self.edgeID = edgeID
    }
    /// True only for the protection a public route may rely on.
    public var encryptedAndVerified: Bool { protection == Self.encrypted && peerVerified }
}

/// What a tensor-parallel worker measured of its link to the peer at load,
/// the way the sharded modes use it (`keyed`: over the keyed data plane, the
/// all-sums sealed): one-way point-to-point records, small and large, and the
/// all-sum at a decode step's width and at a prefill chunk's. Medians, in
/// microseconds. The pair's owner keeps the latest per pair; a placement
/// planner derives the link's costs from it.
public struct ClusterWorkerLinkProbe: Codable, Equatable, Sendable {
    public static let transports: Set<String> = ["jaccl"]
    public let transport: String
    public let keyed: Bool
    public let pointToPointSmallBytes: Int
    public let pointToPointSmallMicroseconds: Int
    public let pointToPointLargeBytes: Int
    public let pointToPointLargeMicroseconds: Int
    public let allSumSmallBytes: Int
    public let allSumSmallMicroseconds: Int
    public let allSumLargeBytes: Int
    public let allSumLargeMicroseconds: Int
    public init(transport: String, keyed: Bool, pointToPointSmallBytes: Int, pointToPointSmallMicroseconds: Int,
                pointToPointLargeBytes: Int, pointToPointLargeMicroseconds: Int, allSumSmallBytes: Int,
                allSumSmallMicroseconds: Int, allSumLargeBytes: Int, allSumLargeMicroseconds: Int) {
        self.transport = transport; self.keyed = keyed
        self.pointToPointSmallBytes = pointToPointSmallBytes; self.pointToPointSmallMicroseconds = pointToPointSmallMicroseconds
        self.pointToPointLargeBytes = pointToPointLargeBytes; self.pointToPointLargeMicroseconds = pointToPointLargeMicroseconds
        self.allSumSmallBytes = allSumSmallBytes; self.allSumSmallMicroseconds = allSumSmallMicroseconds
        self.allSumLargeBytes = allSumLargeBytes; self.allSumLargeMicroseconds = allSumLargeMicroseconds
    }
    /// Known transport, positive figures within bounds, each large size above its small one.
    public var valid: Bool {
        let sizes = [pointToPointSmallBytes, pointToPointLargeBytes, allSumSmallBytes, allSumLargeBytes]
        let times = [pointToPointSmallMicroseconds, pointToPointLargeMicroseconds, allSumSmallMicroseconds, allSumLargeMicroseconds]
        return Self.transports.contains(transport) && sizes.allSatisfy({ (1...(1 << 30)).contains($0) })
            && times.allSatisfy({ (1...60_000_000).contains($0) })
            && pointToPointLargeBytes > pointToPointSmallBytes && allSumLargeBytes > allSumSmallBytes
    }
}

/// This worker's local readiness. The owner must aggregate both workers.
public struct ClusterWorkerReady: Equatable, Sendable {
    public let identity: ClusterWorkerIdentity
    public let rank: Int
    public let profile: ClusterWorkerProfile
    public let executionPlanSHA256: String
    public let requestCapacityBytes: Int
    /// Nil: a worker started without a data-plane credential (plaintext
    /// transfers; qualification and diagnosis only).
    public let dataPlane: ClusterWorkerDataPlane?
    /// The longest context (prompt plus output) this rank's host memory gate
    /// admitted when it became ready, with its weights resident; at most the
    /// profile's `maximumContextTokens`. The profile is what the model and
    /// protocol allow; this is what this Mac can serve now. Nil from a worker
    /// that does not derive one (then the profile's maximum is all it says).
    /// A rank re-derives it while idle and reports it on every keep-warm
    /// answer (`ClusterWorkerEvent.keptWarm`).
    public let servingContextTokens: Int?
    /// The link as a tensor-parallel load measured it; nil from other modes.
    public let linkProbe: ClusterWorkerLinkProbe?
    /// The media contract this rank serves (`ClusterGLMMedia.contract`); nil:
    /// text only, and then the record's bytes are those of a worker without it.
    public let media: String?
    public init(identity: ClusterWorkerIdentity, rank: Int, profile: ClusterWorkerProfile,
                executionPlanSHA256: String, requestCapacityBytes: Int, dataPlane: ClusterWorkerDataPlane? = nil,
                servingContextTokens: Int? = nil, linkProbe: ClusterWorkerLinkProbe? = nil, media: String? = nil) {
        self.identity = identity; self.rank = rank; self.profile = profile
        self.executionPlanSHA256 = executionPlanSHA256; self.requestCapacityBytes = requestCapacityBytes
        self.dataPlane = dataPlane
        self.servingContextTokens = servingContextTokens
        self.linkProbe = linkProbe
        self.media = media
    }
}

public struct ClusterWorkerReservation: Equatable, Sendable {
    public let profileID: String
    public let promptTokenIDs: [Int]
    public let stopTokenIDs: [Int]
    public let outputCount: Int
    public let chunkSize: Int
    /// Same-Mac DispatchTime uptime deadline. Never forward this to another Mac.
    public let deadlineUptimeNanoseconds: UInt64
    /// Additional owner ceiling, not a native resource grant.
    public let capacityLimitBytes: Int
    /// How the decoding rank selects tokens; nil is greedy text, and then the
    /// reservation's bytes are exactly those of a worker without sampling.
    /// Required at every construction, with no default: a reservation rebuilt
    /// from another (a hop, a codec, a local copy) that forgot it would
    /// silently serve a sampled request greedily, the F1 root-cause class.
    public let sampling: ClusterWorkerSampling?
    public let mimoImages: ClusterMiMoImages?
    public let stillImages: ClusterStillImages?
    /// GLM image and video input on the tensor-parallel pair; nil is text, and
    /// then the reservation's bytes are exactly those of a worker without media.
    public let glmMedia: ClusterGLMMedia?
    /// Which way this request goes (`ClusterRequestRouter`); nil is the pair as
    /// placed, and then the reservation's bytes are exactly those of a worker
    /// without routes.
    public let route: ClusterWorkerRoute?
    public init(profileID: String, promptTokenIDs: [Int], stopTokenIDs: [Int], outputCount: Int,
                chunkSize: Int, deadlineUptimeNanoseconds: UInt64, capacityLimitBytes: Int,
                sampling: ClusterWorkerSampling?, route: ClusterWorkerRoute? = nil, mimoImages: ClusterMiMoImages? = nil, stillImages: ClusterStillImages? = nil,
                glmMedia: ClusterGLMMedia? = nil) {
        self.profileID = profileID; self.promptTokenIDs = promptTokenIDs; self.stopTokenIDs = stopTokenIDs
        self.outputCount = outputCount; self.chunkSize = chunkSize
        self.deadlineUptimeNanoseconds = deadlineUptimeNanoseconds; self.capacityLimitBytes = capacityLimitBytes
        self.sampling = sampling; self.route = route; self.mimoImages = mimoImages; self.stillImages = stillImages
        self.glmMedia = glmMedia
    }
}

/// A request routed away from the pair as placed. Both ranks are told the
/// same route and bind it into the request's agreement.
public enum ClusterWorkerRoute: String, Equatable, Sendable {
    /// The decoding rank, which holds every layer under a phase split,
    /// prefills and decodes the whole request by itself: its own single-chip
    /// computation of the whole model. The other rank only publishes the
    /// tokens it relays.
    case decodingRankAlone = "decoding_rank_alone"
}

public enum ClusterWorkerTokenDecision: String, Sendable { case proceed, cleanStop }
public enum ClusterWorkerCancellationReason: String, Sendable {
    case callerCancelled, deadline, peerFailure, runtimeError, outputFailure
}
public enum ClusterWorkerRefusal: String, Sendable { case capacity, deadline, profile, unavailable, busy, unsupported }
public enum ClusterWorkerFinishReason: String, Sendable { case eos, length, clientStop }
public enum ClusterWorkerRetirement: String, Sendable { case clean, cancelled, failed }

public enum ClusterWorkerCommand: Equatable, Sendable {
    case reserve(ClusterWorkerReservation)
    case start
    case tokenDecision(ordinal: Int, decision: ClusterWorkerTokenDecision)
    case cancel(ClusterWorkerCancellationReason)
    case shutdown
    /// Keep-warm tier 2: while idle, exchange one 1x16 record with the peer on
    /// the data plane so its queue pairs stay awake. The owner sequences it to
    /// both ranks; never while a request is reserved or running.
    case keepWarm(ordinal: Int)
}

/// What one rank measured of a request it served (PROD-PLAN S24): sizes,
/// durations and counts only. Every field is optional; a rank sends what it
/// measured and nothing when it measured nothing.
public struct ClusterWorkerRequestTelemetry: Equatable, Sendable {
    /// This rank's wall time for the phase-split hand-off (export or receive to acknowledgement).
    public let handoffNanoseconds: UInt64?
    public let handoffBytes: Int?
    /// Draft tokens this rank's MTP head proposed and the target accepted.
    public let mtpDrafted: Int?
    public let mtpAccepted: Int?
    /// This rank's time from the start of the request to its first committed (or relayed) token.
    public let prefillNanoseconds: UInt64?
    /// MTP rounds (draft and verify) this rank ran for the request.
    public let mtpRounds: Int?
    public init(handoffNanoseconds: UInt64? = nil, handoffBytes: Int? = nil, mtpDrafted: Int? = nil,
                mtpAccepted: Int? = nil, prefillNanoseconds: UInt64? = nil, mtpRounds: Int? = nil) {
        self.handoffNanoseconds = handoffNanoseconds; self.handoffBytes = handoffBytes
        self.mtpDrafted = mtpDrafted; self.mtpAccepted = mtpAccepted; self.prefillNanoseconds = prefillNanoseconds
        self.mtpRounds = mtpRounds
    }
    public var isEmpty: Bool {
        handoffNanoseconds == nil && handoffBytes == nil && mtpDrafted == nil && mtpAccepted == nil && prefillNanoseconds == nil
            && mtpRounds == nil
    }
}

/// The decoding rank's log probabilities for one committed token, from the
/// model's raw (pre-transform) distribution as the product reports them
/// (`CBv2Logprobs`): the token's own, then the `top` most likely tokens in
/// descending order. Sent only for a request whose sampling asks for them.
/// Values travel as IEEE-754 bit patterns, like `ClusterWorkerSampling`.
public struct ClusterWorkerTokenLogprobs: Equatable, Sendable {
    public struct Alternative: Equatable, Sendable {
        public let tokenID: Int
        public let logprob: Float
        public init(tokenID: Int, logprob: Float) { self.tokenID = tokenID; self.logprob = logprob }
    }
    public let logprob: Float
    public let top: [Alternative]
    public init(logprob: Float, top: [Alternative]) { self.logprob = logprob; self.top = top }
}

public enum ClusterWorkerEvent: Equatable, Sendable {
    case ready(ClusterWorkerReady)
    case admitted(reservedBytes: Int)
    case refused(ClusterWorkerRefusal)
    /// `logprobs` only when the request's sampling asks for them (`ClusterWorkerSampling.topLogprobs`).
    case committedToken(ordinal: Int, tokenID: Int, committedTokens: Int, logprobs: ClusterWorkerTokenLogprobs? = nil)
    /// This rank's prefix cache for the running request: prompt tokens it
    /// restored instead of computing (after both ranks agreed to), and the
    /// prompt frontiers it kept after both ranks retired cleanly (ascending,
    /// at most 32). Sent once, just before `finished`, only when either is
    /// not empty.
    case promptCache(reusedTokens: Int, storedFrontiers: [Int])
    /// This rank's measurements of the running request. Sent at most once,
    /// after `promptCache` and just before `finished`, only when not empty.
    case requestTelemetry(ClusterWorkerRequestTelemetry)
    case finished(ClusterWorkerFinishReason)
    case failed(ClusterWorkerCancellationReason)
    /// Local state retirement only. No claim of peer retirement or process fencing.
    case retired(ClusterWorkerRetirement)
    case unavailable(ClusterWorkerCancellationReason)
    case shutdownComplete
    /// The keep-warm exchange of that ordinal completed in `microseconds`.
    /// `servingContextTokens` is the longest context this rank's host memory
    /// gate admits now, re-derived while idle (see `ClusterWorkerReady`); nil
    /// from a worker that does not derive one.
    case keptWarm(ordinal: Int, microseconds: Int, servingContextTokens: Int? = nil)
}

public struct ClusterWorkerCommandFrame: Equatable, Sendable {
    public let membershipEpoch: UUID
    public let sequence: UInt64
    public let requestID: UUID?
    public let command: ClusterWorkerCommand
    public init(membershipEpoch: UUID, sequence: UInt64, requestID: UUID?, command: ClusterWorkerCommand) {
        self.membershipEpoch = membershipEpoch; self.sequence = sequence
        self.requestID = requestID; self.command = command
    }
}

public struct ClusterWorkerEventFrame: Equatable, Sendable {
    public let membershipEpoch: UUID
    public let sequence: UInt64
    public let requestID: UUID?
    public let event: ClusterWorkerEvent
    public init(membershipEpoch: UUID, sequence: UInt64, requestID: UUID?, event: ClusterWorkerEvent) {
        self.membershipEpoch = membershipEpoch; self.sequence = sequence
        self.requestID = requestID; self.event = event
    }
}
