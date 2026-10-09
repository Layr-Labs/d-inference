import Foundation
import CryptoKit

/// The IPv4 link-local address chosen for one Thunderbolt port. It reaches the
/// approval prompt and the owner-only alias record, and nothing else: no
/// report, summary or log line carries it.
struct ClusterLinkLocalAddress: Equatable, Sendable {
    static let netmask = "255.255.0.0"
    private static let validOctets: ClosedRange<UInt8> = 1...254

    /// `169.254.<third>.<fourth>`, each octet in 1...254: RFC 3927 reserves the
    /// first and last /24, and .0 and .255 hosts are avoided.
    let third: UInt8
    let fourth: UInt8

    var dottedDecimal: String { "169.254.\(third).\(fourth)" }

    init?(third: UInt8, fourth: UInt8) {
        guard Self.validOctets.contains(third), Self.validOctets.contains(fourth) else { return nil }
        self.third = third
        self.fourth = fourth
    }

    /// Strict reader for the alias record: canonical decimal octets only.
    init?(dottedDecimal: String) {
        let octets = dottedDecimal.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets[0] == "169", octets[1] == "254",
              let third = Self.canonicalOctet(octets[2]), let fourth = Self.canonicalOctet(octets[3]) else { return nil }
        self.init(third: third, fourth: fourth)
    }

    /// The same Mac and port always get the same address, and two Macs are
    /// very unlikely to get the same one (about 1 in 64,500), so the two ends
    /// of a cable can each choose without talking to the other. The machine
    /// value is only hashed; it is never stored or shown.
    static func derived(machineIdentifier: String, interface: String) -> ClusterLinkLocalAddress {
        let digest = Array(SHA256.hash(data: Data("darkbloom-cluster-link-v1\n\(machineIdentifier)\n\(interface)".utf8)))
        func octet(_ high: UInt8, _ low: UInt8) -> UInt8 {
            validOctets.lowerBound + UInt8((UInt16(high) << 8 | UInt16(low)) % UInt16(validOctets.count))
        }
        return ClusterLinkLocalAddress(validThird: octet(digest[0], digest[1]), validFourth: octet(digest[2], digest[3]))
    }

    private init(validThird: UInt8, validFourth: UInt8) {
        third = validThird
        fourth = validFourth
    }

    private static func canonicalOctet(_ text: Substring) -> UInt8? {
        let digits = text.utf8
        guard (1...3).contains(digits.count), digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              digits.count == 1 || digits.first != UInt8(ascii: "0") else { return nil }
        return UInt8(text)
    }
}
