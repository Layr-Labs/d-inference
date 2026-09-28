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
    public static let requestsPerEpoch = 4096
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

/// This worker's local readiness. The owner must aggregate both workers.
public struct ClusterWorkerReady: Equatable, Sendable {
    public let identity: ClusterWorkerIdentity
    public let rank: Int
    public let profile: ClusterWorkerProfile
    public let executionPlanSHA256: String
    public let requestCapacityBytes: Int
    public init(identity: ClusterWorkerIdentity, rank: Int, profile: ClusterWorkerProfile,
                executionPlanSHA256: String, requestCapacityBytes: Int) {
        self.identity = identity; self.rank = rank; self.profile = profile
        self.executionPlanSHA256 = executionPlanSHA256; self.requestCapacityBytes = requestCapacityBytes
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
}

public enum ClusterWorkerEvent: Equatable, Sendable {
    case ready(ClusterWorkerReady)
    case admitted(reservedBytes: Int)
    case refused(ClusterWorkerRefusal)
    case committedToken(ordinal: Int, tokenID: Int, committedTokens: Int)
    case finished(ClusterWorkerFinishReason)
    case failed(ClusterWorkerCancellationReason)
    /// Local state retirement only. No claim of peer retirement or process fencing.
    case retired(ClusterWorkerRetirement)
    case unavailable(ClusterWorkerCancellationReason)
    case shutdownComplete
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
