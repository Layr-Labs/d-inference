import Foundation

public struct AppAttestResumeChallenge: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let action: String
    public let id: String
    public let encryptedChallenge: EncryptedPayload

    public init(id: String, encryptedChallenge: EncryptedPayload) {
        self.protocolVersion = 1
        self.action = "challenge"
        self.id = id
        self.encryptedChallenge = encryptedChallenge
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case action, id
        case encryptedChallenge = "encrypted_challenge"
    }
}

public struct AppAttestResumeResponse: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let action: String
    public let id: String
    public let ciphertext: String

    public init(id: String, ciphertext: String) {
        self.protocolVersion = 1
        self.action = "response"
        self.id = id
        self.ciphertext = ciphertext
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case action, id, ciphertext
    }
}

public enum AppAttestResumeError: Error, Sendable {
    case invalidMessage
    case invalidBinding
    case expiredChallenge
}

/// This small control protocol is deliberately stricter than ordinary Codable
/// messages: duplicate members, extra fields and non-integer numbers are invalid.
enum AppAttestResumeWire {
    static let maximumBytes = 4096
    static let requestDomain = "darkbloom.app-attest.endpoint-resume.request.v1"
    static let responseDomain = "darkbloom.app-attest.endpoint-resume.response.v1"

    static func validateMessage(_ data: Data, action: String) throws {
        let envelope = try object(data, keys: ["type", "payload"])
        guard envelope["type"] == .string("app_attest_resume"),
              case .object(let payload)? = envelope["payload"] else {
            throw AppAttestResumeError.invalidMessage
        }
        let bodyKey = action == "challenge" ? "encrypted_challenge" : "ciphertext"
        guard Set(payload.keys) == ["protocol", "action", "id", bodyKey],
              payload["protocol"] == .integer(1), payload["action"] == .string(action) else {
            throw AppAttestResumeError.invalidMessage
        }
        _ = try canonicalBase64(string(payload["id"]), count: 32)
        if action == "challenge" {
            guard case .object(let encrypted)? = payload[bodyKey],
                  Set(encrypted.keys) == ["ephemeral_public_key", "ciphertext"] else {
                throw AppAttestResumeError.invalidMessage
            }
            _ = try canonicalBase64(string(encrypted["ephemeral_public_key"]), count: 32)
            _ = try ciphertext(string(encrypted["ciphertext"]))
        } else {
            _ = try ciphertext(string(payload[bodyKey]))
        }
    }

    static func canonicalBase64(_ value: String, count: Int? = nil) throws -> Data {
        guard value.utf8.count <= maximumBytes,
              let data = Data(base64Encoded: value),
              data.base64EncodedString() == value,
              count == nil || data.count == count else {
            throw AppAttestResumeError.invalidMessage
        }
        return data
    }

    static func ciphertext(_ value: String) throws -> Data {
        let data = try canonicalBase64(value)
        guard data.count >= 40 else { throw AppAttestResumeError.invalidMessage }
        return data
    }

    static func string(_ value: Value?) throws -> String {
        guard case .string(let string) = value else { throw AppAttestResumeError.invalidMessage }
        return string
    }

    static func object(_ data: Data, keys: Set<String>) throws -> [String: Value] {
        guard !data.isEmpty, data.count <= maximumBytes else { throw AppAttestResumeError.invalidMessage }
        var parser = Parser(bytes: Array(data))
        guard case .object(let result) = try parser.value(depth: 0),
              Set(result.keys) == keys else { throw AppAttestResumeError.invalidMessage }
        parser.whitespace()
        guard parser.index == parser.bytes.count else { throw AppAttestResumeError.invalidMessage }
        return result
    }

    indirect enum Value: Equatable {
        case object([String: Value])
        case string(String)
        case integer(Int64)
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func whitespace() {
            while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            whitespace()
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        mutating func string() throws -> String {
            whitespace()
            let start = index
            guard consume(34) else { throw AppAttestResumeError.invalidMessage }
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == 34 {
                    return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
                }
                if byte == 92 { index += 1 }
            }
            throw AppAttestResumeError.invalidMessage
        }

        mutating func value(depth: Int) throws -> Value {
            whitespace()
            guard depth <= 3, index < bytes.count else { throw AppAttestResumeError.invalidMessage }
            if bytes[index] == 34 { return .string(try string()) }
            if consume(123) {
                var fields: [String: Value] = [:]
                if consume(125) { return .object(fields) }
                repeat {
                    let key = try string()
                    guard fields[key] == nil, consume(58) else { throw AppAttestResumeError.invalidMessage }
                    fields[key] = try value(depth: depth + 1)
                    if consume(125) { return .object(fields) }
                } while consume(44)
                throw AppAttestResumeError.invalidMessage
            }
            let start = index
            while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
            guard index > start, index == start + 1 || bytes[start] != 48,
                  let number = Int64(String(decoding: bytes[start..<index], as: UTF8.self)) else {
                throw AppAttestResumeError.invalidMessage
            }
            return .integer(number)
        }
    }
}
