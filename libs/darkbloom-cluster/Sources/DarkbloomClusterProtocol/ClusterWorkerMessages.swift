import Foundation

public enum ClusterWorkerProtocolError: Error, Equatable, Sendable {
    case invalid(String)
}

/// Software ceilings, never permission to allocate native state or load a model.
public enum ClusterWorkerLimits {
    public static let version = 1
    public static let commandBytes = 512 * 1024
    public static let eventBytes = 16 * 1024
    public static let promptTokens = 32_768
    public static let outputTokens = 4096
    public static let contextTokens = 32_768
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
    public init(identity: ClusterWorkerIdentity, rank: Int, profile: ClusterWorkerProfile,
                executionPlanSHA256: String, requestCapacityBytes: Int, dataPlane: ClusterWorkerDataPlane? = nil,
                servingContextTokens: Int? = nil) {
        self.identity = identity; self.rank = rank; self.profile = profile
        self.executionPlanSHA256 = executionPlanSHA256; self.requestCapacityBytes = requestCapacityBytes
        self.dataPlane = dataPlane
        self.servingContextTokens = servingContextTokens
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
    public init(profileID: String, promptTokenIDs: [Int], stopTokenIDs: [Int], outputCount: Int,
                chunkSize: Int, deadlineUptimeNanoseconds: UInt64, capacityLimitBytes: Int) {
        self.profileID = profileID; self.promptTokenIDs = promptTokenIDs; self.stopTokenIDs = stopTokenIDs
        self.outputCount = outputCount; self.chunkSize = chunkSize
        self.deadlineUptimeNanoseconds = deadlineUptimeNanoseconds; self.capacityLimitBytes = capacityLimitBytes
    }
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

public enum ClusterWorkerEvent: Equatable, Sendable {
    case ready(ClusterWorkerReady)
    case admitted(reservedBytes: Int)
    case refused(ClusterWorkerRefusal)
    case committedToken(ordinal: Int, tokenID: Int, committedTokens: Int)
    /// This rank's prefix cache for the running request: prompt tokens it
    /// restored instead of computing (after both ranks agreed to), and the
    /// prompt frontiers it kept after both ranks retired cleanly (ascending,
    /// at most 32). Sent once, just before `finished`, only when either is
    /// not empty.
    case promptCache(reusedTokens: Int, storedFrontiers: [Int])
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
