import Foundation

/// The payload of `native_pair_lease`, which renews a session's grant (S15):
/// "DBNL" version 1, the renewal's ordinal (1 for the first renewal) and the
/// grant's new expiry in nanoseconds since 1970, both big-endian. The frame's
/// `expires_at_unix_nano` carries the same expiry. Mirrors
/// `NativePairLeasePayload` / `ParseNativePairLeasePayload`
/// (darkbloom-platform coordinator/protocol/native_pair.go); the shared vector
/// is `native_pair_lease_vector.json`.
public struct NativePairLeaseRenewal: Sendable, Equatable {
    public static let byteCount = 21
    private static let header = Data([68, 66, 78, 76, 1]) // "DBNL", 1

    public let renewal: UInt64
    public let expiresAtUnixNano: Int64

    /// Only a positive ordinal and a positive expiry make a renewal.
    public init?(renewal: UInt64, expiresAtUnixNano: Int64) {
        guard renewal > 0, expiresAtUnixNano > 0 else { return nil }
        self.renewal = renewal; self.expiresAtUnixNano = expiresAtUnixNano
    }

    /// Reads exactly that shape with a positive ordinal and an expiry in
    /// 1...Int64.max; anything else is no renewal.
    public init?(payload: Data) {
        let bytes = [UInt8](payload)
        guard bytes.count == Self.byteCount, Data(bytes[0..<5]) == Self.header else { return nil }
        let renewal = bytes[5..<13].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let expiry = bytes[13..<21].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard expiry <= UInt64(Int64.max) else { return nil }
        self.init(renewal: renewal, expiresAtUnixNano: Int64(expiry))
    }

    public var payload: Data {
        var bytes = Self.header
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: renewal >> UInt64(shift))) }
        let expiry = UInt64(expiresAtUnixNano)
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: expiry >> UInt64(shift))) }
        return bytes
    }
}
