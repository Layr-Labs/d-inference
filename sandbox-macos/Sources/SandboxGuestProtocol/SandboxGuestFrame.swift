import Foundation

/// Wire protocol spoken over the guest channel established by Lume patch 0005.
///
/// The channel is a byte stream, so every message is framed. The host treats
/// every guest frame as untrusted: length caps, a closed kind vocabulary, and
/// strict decoding all apply before any payload reaches the caller.
///
/// The module deliberately has no dependencies. The guest agent links it
/// inside a tenant VM, and nothing about the host runtime belongs there.

public enum SandboxGuestFrameKind: UInt8, Sendable, CaseIterable {
    /// Guest to host, once, immediately on connect.
    case handshake = 1
    /// Host to guest.
    case commandRequest = 2
    /// Guest to host, terminal for one request.
    case commandResult = 3
    /// Guest to host, terminal for one request, when the agent itself failed.
    case failure = 4
}

public struct SandboxGuestFrame: Equatable, Sendable {
    public let kind: SandboxGuestFrameKind
    public let payload: Data

    public init(kind: SandboxGuestFrameKind, payload: Data) {
        self.kind = kind
        self.payload = payload
    }
}

public enum SandboxGuestProtocolError: Error, Equatable, Sendable, CustomStringConvertible {
    case unknownKind(UInt8)
    case payloadTooLarge(Int)
    case malformed(String)

    public var description: String {
        switch self {
        case .unknownKind(let raw):
            return "unknown guest frame kind \(raw)"
        case .payloadTooLarge(let count):
            return "guest frame payload of \(count) bytes exceeds the limit"
        case .malformed(let reason):
            return "malformed guest frame: \(reason)"
        }
    }
}

public enum SandboxGuestFrameCodec {
    /// One byte of kind plus a four-byte big-endian length.
    public static let headerBytes = 5

    /// Sized for the largest legal command result: two base64-encoded 1 MiB
    /// streams plus envelope overhead. A frame claiming more is refused before
    /// a single payload byte is buffered.
    public static let maximumPayloadBytes = 3 * 1024 * 1024

    public static func encode(_ frame: SandboxGuestFrame) throws -> Data {
        guard frame.payload.count <= maximumPayloadBytes else {
            throw SandboxGuestProtocolError.payloadTooLarge(frame.payload.count)
        }
        var encoded = Data(capacity: headerBytes + frame.payload.count)
        encoded.append(frame.kind.rawValue)
        let length = UInt32(frame.payload.count)
        encoded.append(UInt8(truncatingIfNeeded: length >> 24))
        encoded.append(UInt8(truncatingIfNeeded: length >> 16))
        encoded.append(UInt8(truncatingIfNeeded: length >> 8))
        encoded.append(UInt8(truncatingIfNeeded: length))
        encoded.append(frame.payload)
        return encoded
    }

    /// Reads one frame from the front of `buffer`.
    ///
    /// Returns `nil` when the buffer does not yet hold a complete frame, which
    /// is the normal streaming case and not an error. On success the consumed
    /// bytes are removed from `buffer`.
    public static func decode(
        from buffer: inout Data
    ) throws -> SandboxGuestFrame? {
        guard buffer.count >= headerBytes else {
            return nil
        }
        let header = [UInt8](buffer.prefix(headerBytes))
        guard let kind = SandboxGuestFrameKind(rawValue: header[0]) else {
            throw SandboxGuestProtocolError.unknownKind(header[0])
        }
        let length =
            Int(header[1]) << 24
            | Int(header[2]) << 16
            | Int(header[3]) << 8
            | Int(header[4])
        guard length <= maximumPayloadBytes else {
            throw SandboxGuestProtocolError.payloadTooLarge(length)
        }
        guard buffer.count >= headerBytes + length else {
            return nil
        }
        let payloadStart = buffer.index(buffer.startIndex, offsetBy: headerBytes)
        let payloadEnd = buffer.index(payloadStart, offsetBy: length)
        let payload = Data(buffer[payloadStart..<payloadEnd])
        buffer.removeSubrange(buffer.startIndex..<payloadEnd)
        return SandboxGuestFrame(kind: kind, payload: payload)
    }
}
