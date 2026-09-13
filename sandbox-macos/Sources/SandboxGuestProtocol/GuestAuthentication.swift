import CryptoKit
import Foundation
import Security

public struct GuestHello: Codable, Sendable, Equatable {
    public let version: Int
    public let instanceID: UUID
    public let challenge: Data

    public init(instanceID: UUID) throws {
        var random = Data(count: 32)
        let status = random.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw GuestProtocolError.unavailable }
        self.version = GuestProtocolLimits.version; self.instanceID = instanceID
        self.challenge = random
    }

    public func validate(expectedInstanceID: UUID) throws {
        guard version == GuestProtocolLimits.version, instanceID == expectedInstanceID,
              challenge.count == 32 else { throw GuestProtocolError.unauthenticated }
    }
}

public struct GuestAuthenticatedFrame: Codable, Sendable, Equatable {
    public let sequence: UInt64
    public let payload: Data
    public let authentication: Data
}

public struct GuestSessionAuthenticator: Sendable {
    private let hello: GuestHello
    private let key: SymmetricKey
    private var nextRequestSequence: UInt64 = 1
    public enum Direction: String, Sendable { case request, response }

    public init(hello: GuestHello, expectedInstanceID: UUID, credential: Data) throws {
        try hello.validate(expectedInstanceID: expectedInstanceID)
        guard credential.count == 32 else { throw GuestProtocolError.unauthenticated }
        self.hello = hello; self.key = SymmetricKey(data: credential)
    }

    public func seal<T: Encodable>(_ message: T, sequence: UInt64,
                                   direction: Direction) throws -> GuestAuthenticatedFrame {
        guard sequence > 0 else { throw GuestProtocolError.invalidSequence }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let payload = try encoder.encode(message)
        guard payload.count <= GuestProtocolLimits.maximumFrameBytes / 2 else {
            throw GuestProtocolError.invalidMessage
        }
        let tag = HMAC<SHA256>.authenticationCode(
            for: authenticatedBytes(payload, sequence: sequence, direction: direction), using: key)
        return GuestAuthenticatedFrame(sequence: sequence, payload: payload, authentication: Data(tag))
    }

    public func open<T: Decodable>(_ frame: GuestAuthenticatedFrame, as type: T.Type,
                                   direction: Direction) throws -> T {
        guard frame.sequence > 0, frame.authentication.count == 32,
              frame.payload.count <= GuestProtocolLimits.maximumFrameBytes / 2,
              HMAC<SHA256>.isValidAuthenticationCode(frame.authentication,
                authenticating: authenticatedBytes(frame.payload, sequence: frame.sequence, direction: direction), using: key)
        else { throw GuestProtocolError.unauthenticated }
        return try JSONDecoder().decode(type, from: frame.payload)
    }

    public mutating func accept(_ frame: GuestAuthenticatedFrame) throws -> GuestRequest {
        guard frame.sequence == nextRequestSequence, nextRequestSequence < UInt64.max
        else { throw GuestProtocolError.invalidSequence }
        let request = try open(frame, as: GuestRequest.self, direction: .request)
        nextRequestSequence += 1
        return request
    }

    private func authenticatedBytes(_ payload: Data, sequence: UInt64, direction: Direction) -> Data {
        var result = Data("darkbloom-sandbox-guest-v1:\(direction.rawValue)\0".utf8)
        result.append(contentsOf: hello.instanceID.uuidString.lowercased().utf8)
        result.append(0); result.append(hello.challenge)
        var bigEndian = sequence.bigEndian
        withUnsafeBytes(of: &bigEndian) { result.append(contentsOf: $0) }
        result.append(payload)
        return result
    }
}

public enum GuestFrameCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let payload = try encoder.encode(value)
        guard !payload.isEmpty, payload.count <= GuestProtocolLimits.maximumFrameBytes else {
            throw GuestProtocolError.invalidFrame
        }
        var count = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &count) { Data($0) }
        frame.append(payload)
        return frame
    }

    public static func frameSize(header: Data) throws -> Int {
        guard header.count == 4 else { throw GuestProtocolError.invalidFrame }
        let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size > 0, size <= GuestProtocolLimits.maximumFrameBytes else {
            throw GuestProtocolError.invalidFrame
        }
        return Int(size)
    }

    public static func decode<T: Decodable>(_ payload: Data, as type: T.Type) throws -> T {
        guard !payload.isEmpty, payload.count <= GuestProtocolLimits.maximumFrameBytes else {
            throw GuestProtocolError.invalidFrame
        }
        return try JSONDecoder().decode(type, from: payload)
    }
}
