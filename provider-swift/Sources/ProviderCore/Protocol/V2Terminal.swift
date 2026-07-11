import Crypto
import Foundation

/// A SHA-256 digest encoded as standard padded base64 in JSON.
public struct ProtocolV2Digest: Sendable, Hashable, Codable {
    public static let zero = ProtocolV2Digest(bytes: Data(repeating: 0, count: 32))!

    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == 32 else { return nil }
        self.bytes = bytes
    }

    public static func of(_ data: Data) -> ProtocolV2Digest {
        ProtocolV2Digest(bytes: Data(SHA256.hash(data: data)))!
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode(String.self)
        guard let decoded = Data(base64Encoded: encoded),
            decoded.count == 32,
            decoded.base64EncodedString() == encoded
        else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "digest must be 32 bytes of standard base64"
            )
        }
        bytes = decoded
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bytes.base64EncodedString())
    }
}

public typealias Digest = ProtocolV2Digest

/// Opaque provider signature encoded as standard padded base64 in JSON.
public struct V2TerminalSignature: Sendable, Equatable, Codable {
    public let bytes: Data

    public init(bytes: Data) {
        self.bytes = bytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode(String.self)
        guard let decoded = Data(base64Encoded: encoded),
            decoded.base64EncodedString() == encoded
        else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "terminal signature is not valid standard base64"
            )
        }
        bytes = decoded
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bytes.base64EncodedString())
    }
}

public enum V2TerminalOutcome: String, Sendable, Codable {
    case completed
    case cancelled
    case error
}

public enum V2TerminalDisposition: String, Sendable, Codable {
    case settled
    case released
    case settledReviewed = "settled_reviewed"
    case releasedReviewed = "released_reviewed"
    case late
    case conflict
}

public enum V2TerminalValidationError: Error, Sendable, Equatable {
    case identityMismatch
    case digestMismatch
    case missingSignature
    case signatureIdentityMismatch
}

/// A terminal admitted to the historical replay path only after its canonical
/// digest and provider/process-bound signature have been verified.
public struct V2HistoricalTerminalReplay: Sendable, Equatable {
    public let terminal: V2ProviderTerminal

    public init(
        terminal: V2ProviderTerminal,
        verifySignature: (
            _ providerID: ProviderID,
            _ processGeneration: ProviderProcessGenerationID,
            _ digest: ProtocolV2Digest,
            _ signature: Data
        ) -> Bool
    ) throws {
        try terminal.validate(
            expectedIdentity: terminal.identity,
            verifySignature: verifySignature
        )
        self.terminal = terminal
    }
}

/// Canonical signed terminal emitted exactly once per v2 attempt.
public struct V2ProviderTerminal: Sendable, Equatable, Codable {
    public var identity: AttemptIdentity
    public var outcome: V2TerminalOutcome
    public var errorClass: V2StructuredErrorClass?
    public var promptTokens: UInt64
    public var completionTokens: UInt64
    public var reasoningTokens: UInt64
    public var responseHash: ProtocolV2Digest
    public var finalGeneratedTokens: UInt64
    public var rollingDigest: ProtocolV2Digest
    public var model: String
    public var terminalDigest: ProtocolV2Digest
    public var signature: V2TerminalSignature

    public init(
        identity: AttemptIdentity,
        outcome: V2TerminalOutcome,
        errorClass: V2StructuredErrorClass? = nil,
        promptTokens: UInt64,
        completionTokens: UInt64,
        reasoningTokens: UInt64 = 0,
        responseHash: ProtocolV2Digest,
        finalGeneratedTokens: UInt64,
        rollingDigest: ProtocolV2Digest,
        model: String,
        terminalDigest: ProtocolV2Digest = .zero,
        signature: V2TerminalSignature
    ) {
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
        self.terminalDigest = terminalDigest
        self.signature = signature
    }

    /// Sorted, unsigned bytes covered by `terminal_digest`.
    public func canonicalBytes() throws -> Data {
        var output = Data()
        output.appendUTF8("{")
        var needsComma = false

        func emit(_ key: String, _ value: String, quoted: Bool) {
            if needsComma { output.appendUTF8(",") }
            needsComma = true
            output.appendJSONString(key)
            output.appendUTF8(":")
            if quoted {
                output.appendJSONString(value)
            } else {
                output.appendUTF8(value)
            }
        }

        emit("attempt_id", identity.attemptID.description, quoted: true)
        emit("completion_tokens", String(completionTokens), quoted: false)
        if let errorClass {
            emit("error_class", errorClass.rawValue, quoted: true)
        }
        emit("final_generated_tokens", String(finalGeneratedTokens), quoted: false)
        emit("lease_id", identity.leaseID.description, quoted: true)
        emit("model", model, quoted: true)
        emit("outcome", outcome.rawValue, quoted: true)
        emit("prompt_tokens", String(promptTokens), quoted: false)
        emit("provider_id", identity.providerID.description, quoted: true)
        emit(
            "provider_process_generation",
            identity.providerProcessGeneration.description,
            quoted: true
        )
        if reasoningTokens != 0 {
            emit("reasoning_tokens", String(reasoningTokens), quoted: false)
        }
        emit("request_id", identity.requestID.description, quoted: true)
        emit("reservation_id", identity.reservationID.description, quoted: true)
        emit("response_hash", responseHash.bytes.base64EncodedString(), quoted: true)
        emit("rolling_digest", rollingDigest.bytes.base64EncodedString(), quoted: true)
        emit("session_epoch", String(identity.sessionEpoch), quoted: false)
        output.appendUTF8("}")
        return output
    }

    public func computedDigest() throws -> ProtocolV2Digest {
        ProtocolV2Digest.of(try canonicalBytes())
    }

    public func validate(
        expectedIdentity: AttemptIdentity,
        verifySignature: (
            _ providerID: ProviderID,
            _ processGeneration: ProviderProcessGenerationID,
            _ digest: ProtocolV2Digest,
            _ signature: Data
        ) -> Bool
    ) throws {
        guard identity == expectedIdentity else {
            throw V2TerminalValidationError.identityMismatch
        }
        guard try computedDigest() == terminalDigest else {
            throw V2TerminalValidationError.digestMismatch
        }
        guard !signature.bytes.isEmpty else {
            throw V2TerminalValidationError.missingSignature
        }
        guard
            verifySignature(
                identity.providerID,
                identity.providerProcessGeneration,
                terminalDigest,
                signature.bytes
            )
        else {
            throw V2TerminalValidationError.signatureIdentityMismatch
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: V2WireCodingKeys.self)
        identity = try container.decodeAttemptIdentity()
        outcome = try container.decode(V2TerminalOutcome.self, forKey: .outcome)
        errorClass = try container.decodeIfPresent(V2StructuredErrorClass.self, forKey: .errorClass)
        promptTokens = try container.decode(UInt64.self, forKey: .promptTokens)
        completionTokens = try container.decode(UInt64.self, forKey: .completionTokens)
        reasoningTokens = try container.decodeIfPresent(UInt64.self, forKey: .reasoningTokens) ?? 0
        responseHash = try container.decode(ProtocolV2Digest.self, forKey: .responseHash)
        finalGeneratedTokens = try container.decode(UInt64.self, forKey: .finalGeneratedTokens)
        guard
            !(container.contains(.rollingDigest)
                && container.contains(.rollingHashCheckpoint))
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .rollingDigest,
                in: container,
                debugDescription:
                    "duplicate rolling_digest and rolling_hash_checkpoint fields"
            )
        }
        if container.contains(.rollingDigest) {
            rollingDigest = try container.decode(
                ProtocolV2Digest.self, forKey: .rollingDigest)
        } else {
            rollingDigest = try container.decode(
                ProtocolV2Digest.self, forKey: .rollingHashCheckpoint)
        }
        model = try container.decode(String.self, forKey: .model)
        terminalDigest = try container.decode(ProtocolV2Digest.self, forKey: .terminalDigest)
        guard !(container.contains(.seSignature) && container.contains(.signature)) else {
            throw DecodingError.dataCorruptedError(
                forKey: .seSignature,
                in: container,
                debugDescription: "duplicate se_signature and signature fields"
            )
        }
        if container.contains(.seSignature) {
            signature = try container.decode(
                V2TerminalSignature.self, forKey: .seSignature)
        } else {
            signature = try container.decode(
                V2TerminalSignature.self, forKey: .signature)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: V2WireCodingKeys.self)
        try container.encodeAttemptIdentity(identity)
        try container.encode(outcome, forKey: .outcome)
        try container.encodeIfPresent(errorClass, forKey: .errorClass)
        try container.encode(promptTokens, forKey: .promptTokens)
        try container.encode(completionTokens, forKey: .completionTokens)
        if reasoningTokens != 0 {
            try container.encode(reasoningTokens, forKey: .reasoningTokens)
        }
        try container.encode(responseHash, forKey: .responseHash)
        try container.encode(finalGeneratedTokens, forKey: .finalGeneratedTokens)
        try container.encode(rollingDigest, forKey: .rollingDigest)
        try container.encode(model, forKey: .model)
        try container.encode(terminalDigest, forKey: .terminalDigest)
        try container.encode(signature, forKey: .seSignature)
    }
}

extension Data {
    fileprivate mutating func appendUTF8(_ string: String) {
        append(contentsOf: string.utf8)
    }

    fileprivate mutating func appendJSONString(_ string: String) {
        append(0x22)
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x08: appendUTF8("\\b")
            case 0x09: appendUTF8("\\t")
            case 0x0A: appendUTF8("\\n")
            case 0x0C: appendUTF8("\\f")
            case 0x0D: appendUTF8("\\r")
            case 0x22: appendUTF8("\\\"")
            case 0x5C: appendUTF8("\\\\")
            case 0x00...0x1F:
                appendUTF8(String(format: "\\u%04x", scalar.value))
            default:
                append(contentsOf: String(scalar).utf8)
            }
        }
        append(0x22)
    }
}

public struct V2TerminalAck: Sendable, Equatable, Codable {
    public var identity: AttemptIdentity
    public var terminalDigest: ProtocolV2Digest
    public var disposition: V2TerminalDisposition

    public init(
        identity: AttemptIdentity,
        terminalDigest: ProtocolV2Digest,
        disposition: V2TerminalDisposition
    ) {
        self.identity = identity
        self.terminalDigest = terminalDigest
        self.disposition = disposition
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: V2WireCodingKeys.self)
        identity = try container.decodeAttemptIdentity()
        terminalDigest = try container.decode(ProtocolV2Digest.self, forKey: .terminalDigest)
        disposition = try container.decode(V2TerminalDisposition.self, forKey: .disposition)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: V2WireCodingKeys.self)
        try container.encodeAttemptIdentity(identity)
        try container.encode(terminalDigest, forKey: .terminalDigest)
        try container.encode(disposition, forKey: .disposition)
    }
}
