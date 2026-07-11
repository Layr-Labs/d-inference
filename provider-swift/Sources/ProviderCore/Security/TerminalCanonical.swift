/// Canonical provider-terminal construction and response-stream accounting.
///
/// The unsigned terminal byte layout in this file is a cross-language
/// security contract. It mirrors
/// `coordinator-rs/crates/protocol/src/v2/terminal.rs` exactly:
///
/// - keys are emitted in UTF-8 bytewise lexicographic order;
/// - `error_class` and non-zero `reasoning_tokens` are omitted when absent;
/// - digests are standard padded base64;
/// - `terminal_digest` and `se_signature` are not part of the signed bytes.
///
/// Keep the Rust golden vector and `TerminalCanonicalTests` in lockstep when
/// this contract changes.

import CryptoKit
import Foundation

// MARK: - Digest

public enum TerminalCanonicalError: Error, CustomStringConvertible, Sendable, Equatable {
    case invalidDigestLength(Int)
    case invalidIdentityField(name: String, value: String)
    case invalidModel
    case completedTerminalHasErrorClass
    case errorTerminalMissingErrorClass
    case reasoningTokensExceedCompletion
    case completionTokensExceedGenerated
    case completedTokenMismatch
    case sequenceNotIncreasing(previous: UInt64, next: UInt64)
    case cumulativeTokensNotIncreasing(previous: UInt64, next: UInt64)

    public var description: String {
        switch self {
        case .invalidDigestLength(let length):
            return "terminal digest must contain 32 bytes, got \(length)"
        case .invalidIdentityField(let name, let value):
            return "\(name) is not a canonical UUID: \(value)"
        case .invalidModel:
            return "terminal model must be non-empty valid UTF-8 without control characters"
        case .completedTerminalHasErrorClass:
            return "completed terminal cannot carry an error class"
        case .errorTerminalMissingErrorClass:
            return "error terminal requires an error class"
        case .reasoningTokensExceedCompletion:
            return "reasoning tokens cannot exceed completion tokens"
        case .completionTokensExceedGenerated:
            return "completion tokens cannot exceed final generated tokens"
        case .completedTokenMismatch:
            return "completed terminal requires completion tokens to equal final generated tokens"
        case .sequenceNotIncreasing(let previous, let next):
            return "response sequence did not increase: previous=\(previous), next=\(next)"
        case .cumulativeTokensNotIncreasing(let previous, let next):
            return "cumulative generated tokens did not increase: previous=\(previous), next=\(next)"
        }
    }
}

/// A SHA-256 digest encoded as standard padded base64 in JSON.
public struct TerminalDigest: Hashable, Sendable, Codable {
    public static let byteCount = 32
    public static let zero = try! TerminalDigest(bytes: Data(repeating: 0, count: byteCount))

    public let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else {
            throw TerminalCanonicalError.invalidDigestLength(bytes.count)
        }
        self.bytes = bytes
    }

    public init(base64: String) throws {
        guard let decoded = Data(base64Encoded: base64) else {
            throw TerminalCanonicalError.invalidDigestLength(0)
        }
        try self.init(bytes: decoded)
    }

    public static func sha256(_ data: Data) -> TerminalDigest {
        // SHA256.Digest is unconditionally 32 bytes.
        try! TerminalDigest(bytes: Data(SHA256.hash(data: data)))
    }

    public var base64: String {
        bytes.base64EncodedString()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode(String.self)
        do {
            try self.init(base64: encoded)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "expected a standard-base64 SHA-256 digest"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(base64)
    }
}

// MARK: - Attempt identity

/// Identity fence copied into every v2 start, terminal, and ACK.
///
/// String storage keeps this primitive independent of the protocol message
/// definitions. Initializers canonicalize UUID text to lowercase hyphenated
/// form, matching Rust's `UuidBytes::Display`.
public struct TerminalAttemptIdentity: Hashable, Sendable, Codable {
    public let providerID: String
    public let providerProcessGeneration: String
    public let sessionEpoch: UInt64
    public let requestID: String
    public let attemptID: String
    public let reservationID: String
    public let leaseID: String

    public init(
        providerID: String,
        providerProcessGeneration: String,
        sessionEpoch: UInt64,
        requestID: String,
        attemptID: String,
        reservationID: String,
        leaseID: String
    ) throws {
        self.providerID = try Self.canonicalUUID(providerID, name: "provider_id")
        self.providerProcessGeneration = try Self.canonicalUUID(
            providerProcessGeneration, name: "provider_process_generation")
        self.sessionEpoch = sessionEpoch
        self.requestID = try Self.canonicalUUID(requestID, name: "request_id")
        self.attemptID = try Self.canonicalUUID(attemptID, name: "attempt_id")
        self.reservationID = try Self.canonicalUUID(reservationID, name: "reservation_id")
        self.leaseID = try Self.canonicalUUID(leaseID, name: "lease_id")
    }

    public init(
        providerID: UUID,
        providerProcessGeneration: UUID,
        sessionEpoch: UInt64,
        requestID: UUID,
        attemptID: UUID,
        reservationID: UUID,
        leaseID: UUID
    ) {
        self.providerID = providerID.uuidString.lowercased()
        self.providerProcessGeneration = providerProcessGeneration.uuidString.lowercased()
        self.sessionEpoch = sessionEpoch
        self.requestID = requestID.uuidString.lowercased()
        self.attemptID = attemptID.uuidString.lowercased()
        self.reservationID = reservationID.uuidString.lowercased()
        self.leaseID = leaseID.uuidString.lowercased()
    }

    private static func canonicalUUID(_ value: String, name: String) throws -> String {
        let wire = Array(value.utf8)
        let hyphenated =
            wire.count == 36
            && wire.enumerated().allSatisfy { index, byte in
                if [8, 13, 18, 23].contains(index) { return byte == 0x2D }
                return (0x30...0x39).contains(byte)
                    || (0x41...0x46).contains(byte)
                    || (0x61...0x66).contains(byte)
            }
        let compact =
            wire.count == 32
            && wire.allSatisfy { byte in
                (0x30...0x39).contains(byte)
                    || (0x41...0x46).contains(byte)
                    || (0x61...0x66).contains(byte)
            }
        guard hyphenated || compact else {
            throw TerminalCanonicalError.invalidIdentityField(name: name, value: value)
        }
        let parseable: String
        if compact {
            parseable =
                "\(value.prefix(8))-\(value.dropFirst(8).prefix(4))-\(value.dropFirst(12).prefix(4))-\(value.dropFirst(16).prefix(4))-\(value.dropFirst(20))"
        } else {
            parseable = value
        }
        guard let parsed = UUID(uuidString: parseable) else {
            throw TerminalCanonicalError.invalidIdentityField(name: name, value: value)
        }
        return parsed.uuidString.lowercased()
    }

    enum CodingKeys: String, CodingKey {
        case providerID = "provider_id"
        case providerProcessGeneration = "provider_process_generation"
        case sessionEpoch = "session_epoch"
        case requestID = "request_id"
        case attemptID = "attempt_id"
        case reservationID = "reservation_id"
        case leaseID = "lease_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            providerID: container.decode(String.self, forKey: .providerID),
            providerProcessGeneration: container.decode(
                String.self, forKey: .providerProcessGeneration),
            sessionEpoch: container.decode(UInt64.self, forKey: .sessionEpoch),
            requestID: container.decode(String.self, forKey: .requestID),
            attemptID: container.decode(String.self, forKey: .attemptID),
            reservationID: container.decode(String.self, forKey: .reservationID),
            leaseID: container.decode(String.self, forKey: .leaseID)
        )
    }
}

// MARK: - Terminal fields

public enum ProviderTerminalOutcome: String, Codable, Sendable {
    case completed
    case cancelled
    case error
}

/// Mirrors Rust `StructuredErrorClass`.
public enum ProviderTerminalErrorClass: String, Codable, Sendable {
    case invalidRequest = "invalid_request"
    case capacity
    case modelNotReady = "model_not_ready"
    case draining
    case cancelled
    case fault
    case security
}

/// Immutable unsigned terminal facts. The journal constructs this from a
/// durable start plus a `ProviderTerminalDraft`; callers never provide identity,
/// prompt-token, or model fields a second time.
public struct CanonicalProviderTerminal: Equatable, Sendable, Codable {
    public let identity: TerminalAttemptIdentity
    public let outcome: ProviderTerminalOutcome
    public let errorClass: ProviderTerminalErrorClass?
    public let promptTokens: UInt64
    public let completionTokens: UInt64
    public let reasoningTokens: UInt64
    public let responseHash: TerminalDigest
    public let finalGeneratedTokens: UInt64
    public let rollingDigest: TerminalDigest
    public let model: String

    public init(
        identity: TerminalAttemptIdentity,
        outcome: ProviderTerminalOutcome,
        errorClass: ProviderTerminalErrorClass? = nil,
        promptTokens: UInt64,
        completionTokens: UInt64,
        reasoningTokens: UInt64 = 0,
        responseHash: TerminalDigest,
        finalGeneratedTokens: UInt64,
        rollingDigest: TerminalDigest,
        model: String
    ) throws {
        guard Self.validModel(model) else {
            throw TerminalCanonicalError.invalidModel
        }
        guard reasoningTokens <= completionTokens else {
            throw TerminalCanonicalError.reasoningTokensExceedCompletion
        }
        guard completionTokens <= finalGeneratedTokens else {
            throw TerminalCanonicalError.completionTokensExceedGenerated
        }
        switch outcome {
        case .completed:
            guard errorClass == nil else {
                throw TerminalCanonicalError.completedTerminalHasErrorClass
            }
            guard completionTokens == finalGeneratedTokens else {
                throw TerminalCanonicalError.completedTokenMismatch
            }
        case .error:
            guard errorClass != nil else {
                throw TerminalCanonicalError.errorTerminalMissingErrorClass
            }
        case .cancelled:
            break
        }
        self.identity = identity
        self.outcome = outcome
        self.errorClass = errorClass
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.reasoningTokens = reasoningTokens
        self.responseHash = responseHash
        self.finalGeneratedTokens = finalGeneratedTokens
        self.rollingDigest = rollingDigest
        self.model = model
    }

    /// Canonical unsigned JSON, byte-for-byte compatible with Rust's
    /// `ProviderTerminal::canonical_bytes`.
    public func canonicalBytes() -> Data {
        let protocolTerminal = V2ProviderTerminal(
            identity: identity.protocolV2,
            outcome: V2TerminalOutcome(rawValue: outcome.rawValue)!,
            errorClass: errorClass.flatMap {
                V2StructuredErrorClass(rawValue: $0.rawValue)
            },
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            reasoningTokens: reasoningTokens,
            responseHash: responseHash.protocolV2,
            finalGeneratedTokens: finalGeneratedTokens,
            rollingDigest: rollingDigest.protocolV2,
            model: model,
            terminalDigest: .zero,
            signature: V2TerminalSignature(bytes: Data())
        )
        // All fields were validated above; JSONSerialization cannot fail for
        // this closed scalar shape. Protocol v2 is now the single canonicalizer.
        return try! protocolTerminal.canonicalBytes()
    }

    public var terminalDigest: TerminalDigest {
        .sha256(canonicalBytes())
    }

    private static func validModel(_ model: String) -> Bool {
        !model.isEmpty
            && model.utf8.count <= 4_096
            && model.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
    }

    enum CodingKeys: String, CodingKey {
        case identity
        case outcome
        case errorClass = "error_class"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case reasoningTokens = "reasoning_tokens"
        case responseHash = "response_hash"
        case finalGeneratedTokens = "final_generated_tokens"
        case rollingDigest = "rolling_digest"
        case model
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identity: container.decode(TerminalAttemptIdentity.self, forKey: .identity),
            outcome: container.decode(ProviderTerminalOutcome.self, forKey: .outcome),
            errorClass: container.decodeIfPresent(
                ProviderTerminalErrorClass.self, forKey: .errorClass),
            promptTokens: container.decode(UInt64.self, forKey: .promptTokens),
            completionTokens: container.decode(UInt64.self, forKey: .completionTokens),
            reasoningTokens: container.decodeIfPresent(
                UInt64.self, forKey: .reasoningTokens) ?? 0,
            responseHash: container.decode(TerminalDigest.self, forKey: .responseHash),
            finalGeneratedTokens: container.decode(
                UInt64.self, forKey: .finalGeneratedTokens),
            rollingDigest: container.decode(TerminalDigest.self, forKey: .rollingDigest),
            model: container.decode(String.self, forKey: .model)
        )
    }
}

/// The terminal fields that are only known after generation.
public struct ProviderTerminalDraft: Equatable, Sendable {
    public let outcome: ProviderTerminalOutcome
    public let errorClass: ProviderTerminalErrorClass?
    public let completionTokens: UInt64
    public let reasoningTokens: UInt64
    public let responseHash: TerminalDigest
    public let finalGeneratedTokens: UInt64
    public let rollingDigest: TerminalDigest

    public init(
        outcome: ProviderTerminalOutcome,
        errorClass: ProviderTerminalErrorClass? = nil,
        completionTokens: UInt64,
        reasoningTokens: UInt64 = 0,
        responseHash: TerminalDigest,
        finalGeneratedTokens: UInt64,
        rollingDigest: TerminalDigest
    ) {
        self.outcome = outcome
        self.errorClass = errorClass
        self.completionTokens = completionTokens
        self.reasoningTokens = reasoningTokens
        self.responseHash = responseHash
        self.finalGeneratedTokens = finalGeneratedTokens
        self.rollingDigest = rollingDigest
    }
}

/// A frozen terminal that is safe to send only because `TerminalJournal`
/// returns it after the encrypted journal replacement is durable.
public struct FrozenProviderTerminal: Equatable, Sendable, Codable {
    public let terminal: CanonicalProviderTerminal
    public let terminalDigest: TerminalDigest
    public let seSignature: Data
    public let reviewRequired: Bool
    public let recoveryReason: String?

    public init(
        terminal: CanonicalProviderTerminal,
        terminalDigest: TerminalDigest,
        seSignature: Data,
        reviewRequired: Bool = false,
        recoveryReason: String? = nil
    ) {
        self.terminal = terminal
        self.terminalDigest = terminalDigest
        self.seSignature = seSignature
        self.reviewRequired = reviewRequired
        self.recoveryReason = recoveryReason
    }

    /// Protocol-shaped JSON value. This is deliberately separate from the
    /// encrypted journal's Codable envelope.
    public func wireJSONData() throws -> Data {
        var object: [String: Any] = [
            "provider_id": terminal.identity.providerID,
            "provider_process_generation": terminal.identity.providerProcessGeneration,
            "session_epoch": terminal.identity.sessionEpoch,
            "request_id": terminal.identity.requestID,
            "attempt_id": terminal.identity.attemptID,
            "reservation_id": terminal.identity.reservationID,
            "lease_id": terminal.identity.leaseID,
            "outcome": terminal.outcome.rawValue,
            "prompt_tokens": terminal.promptTokens,
            "completion_tokens": terminal.completionTokens,
            "response_hash": terminal.responseHash.base64,
            "final_generated_tokens": terminal.finalGeneratedTokens,
            "rolling_digest": terminal.rollingDigest.base64,
            "model": terminal.model,
            "terminal_digest": terminalDigest.base64,
            "se_signature": seSignature.base64EncodedString(),
        ]
        if let errorClass = terminal.errorClass {
            object["error_class"] = errorClass.rawValue
        }
        if terminal.reasoningTokens != 0 {
            object["reasoning_tokens"] = terminal.reasoningTokens
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    enum CodingKeys: String, CodingKey {
        case terminal
        case terminalDigest = "terminal_digest"
        case seSignature = "se_signature"
        case reviewRequired = "review_required"
        case recoveryReason = "recovery_reason"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        terminal = try container.decode(CanonicalProviderTerminal.self, forKey: .terminal)
        terminalDigest = try container.decode(TerminalDigest.self, forKey: .terminalDigest)
        seSignature = try container.decode(Data.self, forKey: .seSignature)
        reviewRequired =
            try container.decodeIfPresent(
                Bool.self, forKey: .reviewRequired) ?? false
        recoveryReason = try container.decodeIfPresent(
            String.self, forKey: .recoveryReason)
    }
}

// MARK: - Secure Enclave signing boundary

/// Narrow signing boundary used by the durable journal. Production wraps the
/// already-loaded provider identity; tests can use a real software P-256 key
/// without introducing a fake journal implementation.
public protocol TerminalDigestSigner: Sendable {
    var publicKeyBase64: String { get }
    func signTerminalDigest(_ digest: TerminalDigest) throws -> Data
}

/// Secure-Enclave-backed terminal signer using the same identity APIs as
/// attestation and challenge-response.
public struct SecureEnclaveTerminalSigner: TerminalDigestSigner {
    private let identity: any AttestationSigner

    public init(identity: any AttestationSigner) {
        self.identity = identity
    }

    public var publicKeyBase64: String {
        identity.publicKeyBase64
    }

    public func signTerminalDigest(_ digest: TerminalDigest) throws -> Data {
        // Existing identity APIs sign messages with ECDSA/SHA-256. Signing the
        // 32-byte terminal digest is the Rust verifier's expected contract.
        try identity.sign(digest.bytes)
    }
}

// MARK: - Response accounting

/// Rolling response integrity and monotonic stream-accounting helper.
///
/// `responseHash` is SHA-256 over the exact concatenation of response payload
/// bytes. `rollingDigest` is a hash chain:
///
/// `SHA256(previous || sequence_be || cumulative_tokens_be || length_be || bytes)`
///
/// starting with 32 zero bytes. Length is UInt64 network byte order. The
/// sequence must strictly increase and cumulative tokens must never decrease.
/// Equal token counts are required for exact SSE role, finish, usage, and
/// `[DONE]` frames that deliver bytes but no new completion token.
public struct RollingResponseSHA256: @unchecked Sendable {
    public struct Checkpoint: Equatable, Sendable {
        public let sequence: UInt64?
        public let cumulativeTokens: UInt64
        public let responseHash: TerminalDigest
        public let rollingDigest: TerminalDigest
    }

    private var responseHasher = SHA256()
    private var currentRollingDigest = TerminalDigest.zero
    private var lastSequence: UInt64?
    private var lastCumulativeTokens: UInt64 = 0

    public init() {}

    public mutating func append(
        sequence: UInt64,
        cumulativeTokens: UInt64,
        responseBytes: Data
    ) throws -> Checkpoint {
        if let previous = lastSequence, sequence <= previous {
            throw TerminalCanonicalError.sequenceNotIncreasing(previous: previous, next: sequence)
        }
        guard cumulativeTokens >= lastCumulativeTokens else {
            throw TerminalCanonicalError.cumulativeTokensNotIncreasing(
                previous: lastCumulativeTokens,
                next: cumulativeTokens
            )
        }

        var chainInput = Data()
        chainInput.reserveCapacity(56 + responseBytes.count)
        chainInput.append(currentRollingDigest.bytes)
        chainInput.appendUInt64BE(sequence)
        chainInput.appendUInt64BE(cumulativeTokens)
        chainInput.appendUInt64BE(UInt64(responseBytes.count))
        chainInput.append(responseBytes)
        let nextRolling = TerminalDigest.sha256(chainInput)

        responseHasher.update(data: responseBytes)
        currentRollingDigest = nextRolling
        lastSequence = sequence
        lastCumulativeTokens = cumulativeTokens
        return checkpoint
    }

    public var checkpoint: Checkpoint {
        let copy = responseHasher
        let response = try! TerminalDigest(bytes: Data(copy.finalize()))
        return Checkpoint(
            sequence: lastSequence,
            cumulativeTokens: lastCumulativeTokens,
            responseHash: response,
            rollingDigest: currentRollingDigest
        )
    }
}

// MARK: - Protocol-v2 bridges

extension TerminalAttemptIdentity {
    public init(_ identity: AttemptIdentity) throws {
        try self.init(
            providerID: identity.providerID.description,
            providerProcessGeneration: identity.providerProcessGeneration.description,
            sessionEpoch: identity.sessionEpoch,
            requestID: identity.requestID.description,
            attemptID: identity.attemptID.description,
            reservationID: identity.reservationID.description,
            leaseID: identity.leaseID.description
        )
    }

    public var protocolV2: AttemptIdentity {
        // Every string passed the stricter constructor above, so protocol UUID
        // reconstruction cannot fail.
        AttemptIdentity(
            providerID: ProviderID(providerID)!,
            providerProcessGeneration: ProviderProcessGenerationID(
                providerProcessGeneration)!,
            sessionEpoch: sessionEpoch,
            requestID: RequestID(requestID)!,
            attemptID: AttemptID(attemptID)!,
            reservationID: ReservationID(reservationID)!,
            leaseID: LeaseID(leaseID)!
        )
    }
}

extension TerminalDigest {
    public init(_ digest: ProtocolV2Digest) {
        try! self.init(bytes: digest.bytes)
    }

    public var protocolV2: ProtocolV2Digest {
        ProtocolV2Digest(bytes: bytes)!
    }
}

extension FrozenProviderTerminal {
    /// Lossless projection into the protocol type after durable persistence.
    public var protocolV2: V2ProviderTerminal {
        V2ProviderTerminal(
            identity: terminal.identity.protocolV2,
            outcome: V2TerminalOutcome(rawValue: terminal.outcome.rawValue)!,
            errorClass: terminal.errorClass.flatMap {
                V2StructuredErrorClass(rawValue: $0.rawValue)
            },
            promptTokens: terminal.promptTokens,
            completionTokens: terminal.completionTokens,
            reasoningTokens: terminal.reasoningTokens,
            responseHash: terminal.responseHash.protocolV2,
            finalGeneratedTokens: terminal.finalGeneratedTokens,
            rollingDigest: terminal.rollingDigest.protocolV2,
            model: terminal.model,
            terminalDigest: terminalDigest.protocolV2,
            signature: V2TerminalSignature(bytes: seSignature)
        )
    }
}

// MARK: - Canonical byte helpers

extension Data {
    fileprivate mutating func appendUInt64BE(_ value: UInt64) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
