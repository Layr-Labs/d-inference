import Foundation
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
/// Only greedy text generation without speculative decoding is supported today.
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

    public init(identity: DistributedResidentIdentity, profileID: String, requestCapacityBytes: Int) {
        self.identity = identity
        self.profileID = profileID
        self.requestCapacityBytes = requestCapacityBytes
    }
}

public enum DistributedResidentEvent: Sendable {
    /// One target-authoritative committed token. Draft/MTP tokens are not accepted.
    case token(Int)
    case finished(CBv2FinishReason)
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
    /// Abnormal termination (caller cancellation, deadline, output/peer failure).
    /// This is separate from a normal false return from emit.
    func cancel()
    /// Return only after both peers acknowledge retirement or are fenced by the
    /// owner. A lost peer, elapsed timer, or sent cancel is not acknowledgement.
    /// This must also work for a reservation cancelled before start().
    func waitUntilRetired() async
    /// Called exactly once after waitUntilRetired, never on a timeout alone.
    func releaseResources()
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
}

public enum DistributedEngineError: Error, Sendable, Equatable {
    case invalidConfiguration(String)
    case unsupportedRequest(String)
    case unavailable
    case shuttingDown
}
