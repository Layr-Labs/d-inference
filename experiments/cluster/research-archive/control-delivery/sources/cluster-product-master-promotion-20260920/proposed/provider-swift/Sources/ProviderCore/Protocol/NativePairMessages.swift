import DarkbloomClusterProtocol
import Foundation

/// Signed member-envelope mirror of coordinator/protocol/native_pair.go. This value does
/// not authorize a native child; only a future owned, live member handler may
/// translate an explicitly committed start into prelude A. The existing member
/// loop does not consume these messages in this increment.
public struct NativePairMessage: Codable, Sendable, Equatable {
    public let type: String
    public let version: UInt8
    public let memberNonce: String
    public let epoch: String
    public let generation: UInt64
    public let sequence: UInt64
    public let payload: String
    public let signature: String?
    public let prepareBeforeUnixNano: Int64?
    public let expiresAtUnixNano: Int64?

    public static let maximumFrameBytes = 64 * 1024
    public static let inboundTypes: Set<String> = ["native_pair_key_confirmed", "native_pair_mesh", "native_pair_worker_ready", "native_pair_worker_command", "native_pair_worker_event", "native_pair_worker_attach", "native_pair_prepared", "native_pair_hello", "native_pair_confirmation", "native_pair_owner_released", "native_pair_cancel"]
    public static let outboundTypes: Set<String> = ["native_pair_workers_released", "native_pair_mesh_ready", "native_pair_mesh_reply", "native_pair_worker_ready", "native_pair_worker_command", "native_pair_worker_event", "native_pair_prepare", "native_pair_owner_start", "native_pair_binding", "native_pair_peer_confirmation", "native_pair_cancel"]
    public enum Invalid: Error { case publicFrame }
    enum CodingKeys: String, CodingKey {
        case type, version, epoch, generation, sequence, payload, signature
        case memberNonce = "member_nonce"
        case prepareBeforeUnixNano = "prepare_before_unix_nano"
        case expiresAtUnixNano = "expires_at_unix_nano"
    }
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    public init(type: String, memberNonce: String, epoch: String, generation: UInt64, sequence: UInt64,
                payload: Data, signature: Data? = nil, prepareBeforeUnixNano: Int64? = nil, expiresAtUnixNano: Int64? = nil) throws {
        self.type = type; version = 1; self.memberNonce = memberNonce; self.epoch = epoch
        self.generation = generation; self.sequence = sequence; self.payload = payload.base64EncodedString()
        self.signature = signature?.base64EncodedString()
        self.prepareBeforeUnixNano = prepareBeforeUnixNano; self.expiresAtUnixNano = expiresAtUnixNano
        try validate()
    }
    public init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: AnyKey.self)
        guard keys.allKeys.allSatisfy({ CodingKeys(rawValue: $0.stringValue) != nil }) else { throw Invalid.publicFrame }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        for key in c.allKeys { guard try !c.decodeNil(forKey: key) else { throw Invalid.publicFrame } }
        type = try c.decode(String.self, forKey: .type); version = try c.decode(UInt8.self, forKey: .version)
        memberNonce = try c.decode(String.self, forKey: .memberNonce); epoch = try c.decode(String.self, forKey: .epoch)
        generation = try c.decode(UInt64.self, forKey: .generation); sequence = try c.decode(UInt64.self, forKey: .sequence)
        payload = try c.decode(String.self, forKey: .payload); signature = try c.decodeIfPresent(String.self, forKey: .signature)
        prepareBeforeUnixNano = try c.decodeIfPresent(Int64.self, forKey: .prepareBeforeUnixNano)
        expiresAtUnixNano = try c.decodeIfPresent(Int64.self, forKey: .expiresAtUnixNano)
        try validate()
    }
    /// Raw-wire entry point: use the existing strict integer/duplicate-key
    /// scanner before Codable. Adding LF is local framing only, never wire IO.
    public static func decodePublicFrame(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumFrameBytes, !data.contains(10) else { throw Invalid.publicFrame }
        do {
            var framed = data; framed.append(10)
            try validateClusterWorkerEnvelope(framed, commandStream: true)
            return try JSONDecoder().decode(Self.self, from: data)
        } catch { throw Invalid.publicFrame }
    }
    public func validate() throws {
        guard version == 1, Self.inboundTypes.contains(type) || Self.outboundTypes.contains(type),
              Self.canonicalHex(memberNonce, bytes: 32), Self.canonicalHex(epoch, bytes: 16),
              generation > 0, sequence > 0,
              let bytes = Data(base64Encoded: payload), bytes.count <= 32 * 1024,
              bytes.base64EncodedString() == payload,
              (prepareBeforeUnixNano ?? 0) >= 0, (expiresAtUnixNano ?? 0) >= 0 else { throw Invalid.publicFrame }
        if let signature {
            guard let bytes = Data(base64Encoded: signature), (8...72).contains(bytes.count),
                  bytes.base64EncodedString() == signature else { throw Invalid.publicFrame }
        }
    }
    /// Existing Secure Enclave P-256 signs SHA256 of this domain-bound value.
    /// Traffic secrets never belong here. Explicit worker_* records carry bounded
    /// inference control only over the already authenticated TLS connection.
    public func signingBytes() throws -> Data {
        try validate()
        var b = Data("darkbloom/coordinator-native-pair/member-message/v1\0".utf8)
        for string in [type, memberNonce, epoch] {
            let bytes = Data(string.utf8); Self.append(UInt32(bytes.count), to: &b); b.append(bytes)
        }
        b.append(version); Self.append(generation, to: &b); Self.append(sequence, to: &b)
        let bytes = Data(base64Encoded: payload)!
        Self.append(UInt32(bytes.count), to: &b); b.append(bytes)
        Self.append(UInt64(prepareBeforeUnixNano ?? 0), to: &b); Self.append(UInt64(expiresAtUnixNano ?? 0), to: &b)
        return b
    }
    private static func canonicalHex(_ s: String, bytes: Int) -> Bool {
        s.utf8.count == bytes * 2 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } && s.utf8.contains { $0 != 48 }
    }
    private static func append<T: FixedWidthInteger & UnsignedInteger>(_ x: T, to data: inout Data) {
        for shift in stride(from: T.bitWidth - 8, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: x >> shift)) }
    }
}
