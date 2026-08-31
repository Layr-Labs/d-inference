import CryptoKit
import Foundation

public enum PrivateV2Endpoint: String, Codable, Sendable, Equatable, CaseIterable {
    case chatCompletions = "chat.completions"
    case responses
    case completions
    case messages
}

public struct PrivateV2Request: Sendable, Equatable {
    public let version: String
    public let leaseId: String
    public let requestId: String
    public let routeId: String
    public let model: String
    public let endpoint: PrivateV2Endpoint
    public let stream: Bool
    /// RFC3339/RFC3339Nano text. The exact bytes are part of the transcript.
    public let deadline: String
    public let transcriptDigest: String
    public let processCertificateDigest: String
    public let releaseBinaryHash: String
    public let modelManifestHash: String
    public let releaseGeneration: UInt64
    public let modelGeneration: UInt64
    public let requestedMaxOutputTokens: UInt64
    public let routeMode: String
    public let ownerBinding: String
    public let requiresVision: Bool
    public let kdfSalt: String
    public let clientPublicKey: String
    public let nonce: String
    public let ciphertext: String

    public init(
        version: String,
        leaseId: String,
        requestId: String,
        routeId: String,
        model: String,
        endpoint: PrivateV2Endpoint,
        stream: Bool,
        deadline: String,
        transcriptDigest: String,
        processCertificateDigest: String,
        releaseBinaryHash: String,
        modelManifestHash: String,
        releaseGeneration: UInt64,
        modelGeneration: UInt64,
        requestedMaxOutputTokens: UInt64,
        routeMode: String,
        ownerBinding: String,
        requiresVision: Bool,
        kdfSalt: String,
        clientPublicKey: String,
        nonce: String,
        ciphertext: String
    ) {
        self.version = version
        self.leaseId = leaseId
        self.requestId = requestId
        self.routeId = routeId
        self.model = model
        self.endpoint = endpoint
        self.stream = stream
        self.deadline = deadline
        self.transcriptDigest = transcriptDigest
        self.processCertificateDigest = processCertificateDigest
        self.releaseBinaryHash = releaseBinaryHash
        self.modelManifestHash = modelManifestHash
        self.releaseGeneration = releaseGeneration
        self.modelGeneration = modelGeneration
        self.requestedMaxOutputTokens = requestedMaxOutputTokens
        self.routeMode = routeMode
        self.ownerBinding = ownerBinding
        self.requiresVision = requiresVision
        self.kdfSalt = kdfSalt
        self.clientPublicKey = clientPublicKey
        self.nonce = nonce
        self.ciphertext = ciphertext
    }
}

extension PrivateV2Request: Codable {
    enum CodingKeys: String, CodingKey {
        case version
        case leaseId = "lease_id"
        case requestId = "request_id"
        case routeId = "route_id"
        case model, endpoint, stream, deadline
        case transcriptDigest = "transcript_digest"
        case processCertificateDigest = "process_certificate_digest"
        case releaseBinaryHash = "release_binary_hash"
        case modelManifestHash = "model_manifest_hash"
        case releaseGeneration = "release_generation"
        case modelGeneration = "model_generation"
        case requestedMaxOutputTokens = "requested_max_output_tokens"
        case routeMode = "route_mode"
        case ownerBinding = "owner_binding"
        case requiresVision = "requires_vision"
        case kdfSalt = "kdf_salt"
        case clientPublicKey = "client_public_key"
        case nonce, ciphertext
    }
}

public struct PrivateV2Usage: Codable, Sendable, Equatable {
    public let promptTokens: UInt64
    public let completionTokens: UInt64
    public let totalTokens: UInt64

    public init(promptTokens: UInt64, completionTokens: UInt64) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        let (total, overflow) = promptTokens.addingReportingOverflow(completionTokens)
        self.totalTokens = overflow ? UInt64.max : total
    }

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

public struct PrivateV2Chunk: Codable, Sendable, Equatable {
    public let version: String
    public let requestId: String
    public let sequence: UInt64
    public let terminal: Bool
    public let nonce: String
    public let ciphertext: String
    public let usage: PrivateV2Usage?
    public let failureCode: String?
    public let statusCode: Int?

    public init(
        version: String = PrivateV2Protocol.version,
        requestId: String,
        sequence: UInt64,
        terminal: Bool,
        nonce: String,
        ciphertext: String,
        usage: PrivateV2Usage? = nil,
        failureCode: String? = nil,
        statusCode: Int? = nil
    ) {
        self.version = version
        self.requestId = requestId
        self.sequence = sequence
        self.terminal = terminal
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.usage = terminal ? usage : nil
        self.failureCode = terminal ? failureCode : nil
        self.statusCode = terminal ? statusCode : nil
    }

    enum CodingKeys: String, CodingKey {
        case version
        case requestId = "request_id"
        case sequence, terminal, nonce, ciphertext, usage
        case failureCode = "failure_code"
        case statusCode = "status_code"
    }
}

public enum PrivateV2Protocol {
    public static let version = "private_v2"
    public static let replayCapacity = 8_192
    public static let maximumChunksPerRequest: UInt64 = 8_192
    public static let maximumOutputTokens: UInt64 = 8_000
    public static let maximumLeaseLifetime: TimeInterval = 60
    public static let requestInfoPrefix = Data("darkbloom/private-v2/request\0".utf8)
    public static let responseInfoPrefix = Data("darkbloom/private-v2/response\0".utf8)
}

public enum PrivateV2Error: Error, Equatable, Sendable {
    case invalidVersion
    case invalidBase64URL
    case invalidLength
    case invalidDeadline
    case deadlineExpired
    case leaseTooLong
    case transcriptMismatch
    case requestMismatch
    case releaseMismatch
    case modelMismatch
    case replay
    case replayCapacity
    case decryptionFailed
    case invalidInnerRequest
    case invalidBody
    case encryptionFailed
    case terminalAlreadySent
}

public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ value: String) throws -> Data {
        guard !value.contains("="),
              value.utf8.allSatisfy({
                  ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
                    || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95
              })
        else { throw PrivateV2Error.invalidBase64URL }
        let remainder = value.utf8.count % 4
        guard remainder != 1 else { throw PrivateV2Error.invalidBase64URL }
        var standard = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        if remainder != 0 { standard += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: standard), encode(data) == value else {
            throw PrivateV2Error.invalidBase64URL
        }
        return data
    }
}

public struct PrivateV2Transcript: Sendable, Equatable {
    public let leaseId: String
    public let requestId: String
    public let routeId: String
    public let endpoint: PrivateV2Endpoint
    public let model: String
    public let processCertificateDigest: String
    public let releaseBinaryHash: String
    public let modelManifestHash: String
    public let releaseGeneration: UInt64
    public let modelGeneration: UInt64
    public let ownerBinding: String
    public let requestedMaxOutputTokens: UInt64
    public let requiresVision: Bool
    public let routeMode: String
    public let deadline: String

    public init(request: PrivateV2Request) {
        leaseId = request.leaseId
        requestId = request.requestId
        routeId = request.routeId
        endpoint = request.endpoint
        model = request.model
        processCertificateDigest = request.processCertificateDigest
        releaseBinaryHash = request.releaseBinaryHash
        modelManifestHash = request.modelManifestHash
        releaseGeneration = request.releaseGeneration
        modelGeneration = request.modelGeneration
        ownerBinding = request.ownerBinding
        requestedMaxOutputTokens = request.requestedMaxOutputTokens
        requiresVision = request.requiresVision
        routeMode = request.routeMode
        deadline = request.deadline
    }

    /// Canonical JSON uses lexicographically sorted keys and no whitespace,
    /// matching Go's encoding/json map ordering and JSONEncoder.sortedKeys.
    public func canonicalJSON() -> Data {
        var output = Data()
        output.append(contentsOf: [UInt8(ascii: "{")])
        appendStringField("deadline", deadline, to: &output)
        appendStringField("endpoint", endpoint.rawValue, to: &output, comma: true)
        appendStringField("lease_id", leaseId, to: &output, comma: true)
        appendStringField("model", model, to: &output, comma: true)
        appendUIntField("model_generation", modelGeneration, to: &output, comma: true)
        appendStringField("model_manifest_hash", modelManifestHash, to: &output, comma: true)
        appendStringField("owner_binding", ownerBinding, to: &output, comma: true)
        appendStringField("process_certificate_digest", processCertificateDigest, to: &output, comma: true)
        appendStringField("release_binary_hash", releaseBinaryHash, to: &output, comma: true)
        appendUIntField("release_generation", releaseGeneration, to: &output, comma: true)
        appendStringField("request_id", requestId, to: &output, comma: true)
        appendUIntField(
            "requested_max_output_tokens", requestedMaxOutputTokens,
            to: &output, comma: true)
        appendBoolField("requires_vision", requiresVision, to: &output, comma: true)
        appendStringField("route_id", routeId, to: &output, comma: true)
        appendStringField("route_mode", routeMode, to: &output, comma: true)
        output.append(contentsOf: [UInt8(ascii: "}")])
        return output
    }

    public func digest() -> Data { Data(SHA256.hash(data: canonicalJSON())) }

    private func appendStringField(
        _ key: String, _ value: String, to output: inout Data, comma: Bool = false
    ) {
        if comma { output.append(contentsOf: [UInt8(ascii: ",")]) }
        output.append(goJSONString(key))
        output.append(contentsOf: [UInt8(ascii: ":")])
        output.append(goJSONString(value))
    }

    private func appendUIntField(
        _ key: String, _ value: UInt64, to output: inout Data, comma: Bool
    ) {
        if comma { output.append(contentsOf: [UInt8(ascii: ",")]) }
        output.append(goJSONString(key))
        output.append(contentsOf: [UInt8(ascii: ":")])
        output.append(Data(String(value).utf8))
    }


    private func appendBoolField(
        _ key: String, _ value: Bool, to output: inout Data, comma: Bool
    ) {
        if comma { output.append(contentsOf: [UInt8(ascii: ",")]) }
        output.append(goJSONString(key))
        output.append(contentsOf: [UInt8(ascii: ":")])
        output.append(Data((value ? "true" : "false").utf8))
    }
    private func goJSONString(_ string: String) -> Data {
        var out = Data([UInt8(ascii: "\"")])
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22: out.append(Data("\\\"".utf8))
            case 0x5c: out.append(Data("\\\\".utf8))
            case 0x08: out.append(Data("\\b".utf8))
            case 0x0c: out.append(Data("\\f".utf8))
            case 0x0a: out.append(Data("\\n".utf8))
            case 0x0d: out.append(Data("\\r".utf8))
            case 0x09: out.append(Data("\\t".utf8))
            case 0x00...0x1f, 0x3c, 0x3e, 0x26, 0x2028, 0x2029:
                out.append(Data(String(format: "\\u%04x", scalar.value).utf8))
            default:
                out.append(Data(String(scalar).utf8))
            }
        }
        out.append(contentsOf: [UInt8(ascii: "\"")])
        return out
    }
}
extension PrivateV2Transcript {
    public init(
        leaseId: String, requestId: String, routeId: String,
        endpoint: PrivateV2Endpoint, model: String,
        processCertificateDigest: String, releaseBinaryHash: String,
        modelManifestHash: String, releaseGeneration: UInt64,
        modelGeneration: UInt64, ownerBinding: String,
        requestedMaxOutputTokens: UInt64, requiresVision: Bool,
        routeMode: String, deadline: String
    ) {
        self.leaseId = leaseId
        self.requestId = requestId
        self.routeId = routeId
        self.endpoint = endpoint
        self.model = model
        self.processCertificateDigest = processCertificateDigest
        self.releaseBinaryHash = releaseBinaryHash
        self.modelManifestHash = modelManifestHash
        self.releaseGeneration = releaseGeneration
        self.modelGeneration = modelGeneration
        self.ownerBinding = ownerBinding
        self.requestedMaxOutputTokens = requestedMaxOutputTokens
        self.requiresVision = requiresVision
        self.routeMode = routeMode
        self.deadline = deadline
    }
}

