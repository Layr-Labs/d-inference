import Foundation

/// This candidate is not qualified for unattended serving. The caller must keep
/// the legacy path as the default, and must NOT run its stall restart for a worker.
public enum AppAttestWorkerSelection {
    public static let qualificationEnvironment = "DARKBLOOM_APP_ATTEST_WORKER_QUALIFICATION"
    public static var qualificationCandidateEnabled: Bool {
        enabled(in: ProcessInfo.processInfo.environment)
    }
    static func enabled(in environment: [String: String]) -> Bool { environment[qualificationEnvironment] == "1" }
}

public enum AppAttestWorkerError: String, Error, Sendable {
    case qualificationRequired, invalidMessage, frameTooLarge, deadlineExceeded
    case connectionClosed, systemFailure, unauthenticatedPeer, executableChanged
    case stopped, busy, staleExchange, childWouldNotExit, credentialWriterBusy
}

/// Only the client constructs these requests. The injected operation decrypts
/// with its captured ProviderLoop key, never a key or endpoint from the request.
public struct AppAttestWorkerCustodyRequest: Sendable {
    public enum Purpose: Sendable { case workerBinding, assertion }
    public let purpose: Purpose
    public let generation: UUID
    public let session: String
    public let encryptedChallenge: ShadowEncryptedChallenge
}

public struct AppAttestWorkerReply: Codable, Sendable {
    public let payload: AppAttestShadowPayload
    /// Worker credential observations only. Parent process diagnostics stay in
    /// ProviderLoop and must be attached there, not inferred from the child PID.
    public let localStatus: AppAttestLocalStatus?
    /// Local IPC only. Never forward these observations as coordinator claims.
    public let runtimeDiagnostics: AppAttestWorkerRuntimeDiagnostics?
    let operationOutstanding: Bool
}

public protocol AppAttestWorkerExchangeClient: Sendable {
    func respond(to request: AppAttestShadowPayload, status: AppAttestStatus) async throws -> AppAttestWorkerReply
    func cancelExchange() async throws
    func stop() async throws
}

struct WorkerBootstrap: Codable, Sendable {
    static let version = 1
    let version: Int
    let generation: UUID
    let secret: Data
    let parentAuditToken: Data
    let socketPath: String
    let scope: String
    let endpointPublicKey: String
    let qualificationFaultsAllowed: Bool
}

struct WorkerFrame: Codable, Sendable {
    let generation: UUID
    let sequence: UInt64
    let body: Body

    enum Body: Codable, Sendable {
        case hello(secret: Data)
        case custodyChallenge(ShadowEncryptedChallenge)
        case custodyAnswer(String)
        case authenticated
        case exchange(AppAttestShadowPayload, AppAttestStatus)
        case reply(AppAttestWorkerReply)
        case armAssertionCallbackDiscard
        case assertionCallbackDiscardArmed
        case assertionQualificationEvent(AppAttestWorkerClient.QualificationAssertionEvent.Phase)
    }
}

/// At most two ordered operational observations for one armed assertion. This
/// does not grant trust, complete a proof, or change the exchange deadline.
struct WorkerAssertionEventOrder {
    private var submitted = false
    private var discarded = false

    mutating func accept(_ phase: AppAttestWorkerClient.QualificationAssertionEvent.Phase) throws {
        switch phase {
        case .submitted:
            guard !submitted else { throw AppAttestWorkerError.invalidMessage }
            submitted = true
        case .callbackDiscarded:
            guard submitted, !discarded else { throw AppAttestWorkerError.invalidMessage }
            discarded = true
        }
    }
}

/// Sequence zero is exclusively the launch/custody handshake. Each subsequent
/// request/reply pair has one strictly increasing sequence in this generation.
struct WorkerExchangeOrder: Sendable {
    let generation: UUID
    private(set) var sequence: UInt64 = 0

    mutating func next() throws -> UInt64 {
        guard sequence < UInt64.max else { throw AppAttestWorkerError.staleExchange }
        sequence += 1
        return sequence
    }

    func require(_ frame: WorkerFrame) throws {
        guard frame.generation == generation, frame.sequence == sequence else {
            throw AppAttestWorkerError.staleExchange
        }
    }
}

enum WorkerRequestValidation {
    static func validate(_ request: AppAttestShadowPayload, status: AppAttestStatus) throws {
        guard ["prepare", "attest", "assert"].contains(request.action),
              request.protocolVersion == 3,
              canonical32(request.session),
              let account = request.accountScope, account.count == 64,
              account.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let environment = request.environment, ["production", "development"].contains(environment),
              request.proof == nil, request.status == nil, request.result == nil,
              request.enrollmentSession == nil,
              status.values.allSatisfy({ $0.utf8.count <= 256 }),
              status.hardwareValues.allSatisfy({ $0.utf8.count <= 256 }),
              (status.attestationPublicKey?.utf8.count ?? 0) <= 256 else {
            throw AppAttestWorkerError.invalidMessage
        }
        if request.action != "prepare" {
            guard let key = request.keyID, canonical32(key) else { throw AppAttestWorkerError.invalidMessage }
        }
        if let challenge = request.challenge, !canonical32(challenge) { throw AppAttestWorkerError.invalidMessage }
        if let encrypted = request.encryptedChallenge {
            guard canonical32(encrypted.ephemeralPublicKey),
                  let bytes = Data(base64Encoded: encrypted.ciphertext), (40...512).contains(bytes.count) else {
                throw AppAttestWorkerError.invalidMessage
            }
        }
    }

    static func canonical32(_ string: String) -> Bool {
        guard let bytes = Data(base64Encoded: string), bytes.count == 32 else { return false }
        return bytes.base64EncodedString() == string
    }
}
