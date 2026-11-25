import Foundation

/// Why a blind request was refused, as named in its signed refusal.
public enum BlindRefusalReason: String, Error, Sendable, Equatable, CaseIterable {
    case signatureInvalid = "signature_invalid"
    case unsupportedVersion = "unsupported_version"
    case notInSet = "not_in_set"
    case metaMismatch = "meta_mismatch"
    case sealUnopenable = "seal_unopenable"
    case bindingMissing = "binding_missing"
    case bindingMismatch = "binding_mismatch"
    case stale
    case replayed
    case modelMismatch = "model_mismatch"
    case boundExceeded = "bound_exceeded"
    case traitsMismatch = "traits_mismatch"
    case promptBoundExceeded = "prompt_bound_exceeded"
    /// The opened body asks for something no engine here serves: a content
    /// part, audio, template controls or a prompt length. Only this reason
    /// leaves in clear, never which.
    case contentUnsupported = "content_unsupported"
    case posture

    /// 502 when the request could not be checked or this Mac cannot serve it
    /// blind; 400 when the request itself fails its terms.
    public var statusCode: UInt16 {
        switch self {
        case .signatureInvalid, .posture: 502
        default: 400
        }
    }
}

/// A statement the provider signs with its Secure Enclave key about a blind
/// request: the bytes are `LP` (4-byte big-endian length, then the bytes) of
/// a domain string and then each field's string form, in order. The JSON form
/// sent beside the signature has one member per field, integers as numbers.
public struct BlindStatement: Sendable, Equatable {
    public enum Value: Sendable, Equatable, Codable {
        case text(String)
        case integer(Int64)

        var stringForm: String {
            switch self {
            case .text(let text): text
            case .integer(let number): String(number)
            }
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int64.self) {
                self = .integer(number)
            } else {
                self = .text(try container.decode(String.self))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let text): try container.encode(text)
            case .integer(let number): try container.encode(number)
            }
        }
    }

    public let domain: String
    public let fields: [(name: String, value: Value)]

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.domain == rhs.domain && lhs.fields.elementsEqual(rhs.fields) { $0.name == $1.name && $0.value == $1.value }
    }

    /// The bytes the signature covers.
    public var signedBytes: Data {
        var bytes = Data()
        func append(_ text: String) {
            let utf8 = Data(text.utf8)
            withUnsafeBytes(of: UInt32(utf8.count).bigEndian) { bytes.append(contentsOf: $0) }
            bytes.append(utf8)
        }
        append(domain)
        for field in fields { append(field.value.stringForm) }
        return bytes
    }

    /// Signs `signedBytes` (DER ECDSA P-256 over SHA-256) and returns the
    /// `{statement, signature}` object.
    func signed(by signer: any AttestationSigner) throws -> SignedBlindStatement {
        SignedBlindStatement(
            statement: Dictionary(fields.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first }),
            signature: try signer.sign(signedBytes).base64EncodedString())
    }

    // MARK: - The two statements

    static func refusal(requestID: String, signedRequestSHA256: Data?, reason: BlindRefusalReason,
                        issuedAtMs: Int64) -> BlindStatement {
        BlindStatement(domain: "darkbloom-blind-refusal-v1", fields: [
            ("request_id", .text(requestID)),
            ("signed_request_sha256", .text(signedRequestSHA256?.base64EncodedString() ?? "")),
            ("reason", .text(reason.rawValue)),
            ("issued_at_ms", .integer(issuedAtMs)),
        ])
    }

    struct UsageTerms: Equatable {
        var requestID: String
        var signedRequestSHA256: Data
        var recipientPublicKey: String
        var clientPublicKey: String
        var clientNonce: String
        var model: String
        var maxTokens: Int
    }

    static func usage(_ terms: UsageTerms, usage: UsageInfo, finishReason: BlindFinishReason, chunkCount: UInt64,
                      framesSHA256: Data, sealedUsageSHA256: Data, issuedAtMs: Int64) -> BlindStatement {
        BlindStatement(domain: "darkbloom-blind-usage-v1", fields: [
            ("request_id", .text(terms.requestID)),
            ("signed_request_sha256", .text(terms.signedRequestSHA256.base64EncodedString())),
            ("recipient_public_key", .text(terms.recipientPublicKey)),
            ("client_public_key", .text(terms.clientPublicKey)),
            ("client_nonce", .text(terms.clientNonce)),
            ("model", .text(terms.model)),
            ("max_tokens", .integer(Int64(terms.maxTokens))),
            ("prompt_tokens", .integer(Int64(clamping: usage.promptTokens))),
            ("completion_tokens", .integer(Int64(clamping: usage.completionTokens))),
            ("reasoning_tokens", .integer(Int64(clamping: usage.reasoningTokens))),
            ("cached_tokens", .integer(Int64(clamping: usage.cachedTokens ?? 0))),
            ("finish_reason", .text(finishReason.rawValue)),
            ("chunk_count", .integer(Int64(clamping: chunkCount))),
            ("frames_sha256", .text(framesSHA256.base64EncodedString())),
            ("sealed_usage_sha256", .text(sealedUsageSHA256.base64EncodedString())),
            ("issued_at_ms", .integer(issuedAtMs)),
        ])
    }
}

/// A signed statement as sent (`blind_usage`, `blind_refusal`): the
/// statement's fields by name, and the base64 of the DER signature over its
/// `signedBytes`. A verifier rebuilds the bytes from the fields in the
/// statement's documented order.
public struct SignedBlindStatement: Sendable, Equatable, Codable {
    public let statement: [String: BlindStatement.Value]
    public let signature: String
}

/// How a blind response ended, as its usage statement names it.
public enum BlindFinishReason: String, Sendable, Equatable {
    case stop
    case length
    case toolCalls = "tool_calls"
    case cancelled
    case error

    init(_ reason: SealedTerminalFields.FinishReason) {
        switch reason {
        case .stop: self = .stop
        case .length: self = .length
        case .toolCalls: self = .toolCalls
        case .cancelled: self = .cancelled
        }
    }
}
