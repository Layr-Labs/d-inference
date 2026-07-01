// Shared lowercase-hex encoding for byte sequences (hash digests, raw key
// bytes, APNs device tokens). Replaces the hand-rolled
// `.map { String(format: "%02x", $0) }.joined()` copies that were scattered
// across the module.

import Foundation

extension Sequence where Element == UInt8 {
    /// Lowercase hexadecimal representation of the bytes (e.g. `"0a1b2c"`).
    ///
    /// Defined on `Sequence` (not just `Data`) so `SHA256.Digest`, `Data`, and
    /// `[UInt8]` all share the one implementation without intermediate copies.
    /// `public` so downstream targets (the `darkbloom` CLI) can use it too.
    public var hexString: String {
        var out = [UInt8]()
        out.reserveCapacity(underestimatedCount * 2)
        for byte in self {
            out.append(Self.hexDigits[Int(byte >> 4)])
            out.append(Self.hexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static var hexDigits: [UInt8] { Array("0123456789abcdef".utf8) }
}
