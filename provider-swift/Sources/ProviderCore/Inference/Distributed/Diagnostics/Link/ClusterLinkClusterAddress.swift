import Foundation

/// The fixed IPv4 address an isolated cluster port gets (link setup v2), in
/// the private subnet every Darkbloom cluster link shares: `10.219.0.0/16`.
///
/// Why not the link-local `169.254.0.0/16` of the first version: macOS gives
/// the primary interface (usually Wi-Fi) the unscoped route for that subnet,
/// so a TCP connection to the other Mac's link-local address leaves through
/// Wi-Fi and never reaches the cable. The pair's TCP traffic (the JACCL
/// coordinator socket, SSH) only worked because Internet Sharing's DHCP subnet
/// also ran over the cable. A private subnet that nothing else on the Mac uses
/// gets an ordinary interface route through the cluster port on both Macs.
///
/// The two octets after the prefix are the ones the first version derives
/// for the same Mac and port, so both ends of a cable still choose without
/// talking to each other, and a port keeps the host part it had.
///
/// Like `ClusterLinkLocalAddress`, it appears only in commands (the approval,
/// a dry run, the owner-only record), never in a report or a summary.
struct ClusterLinkClusterAddress: Equatable, Sendable {
    static let netmask = "255.255.0.0"
    /// The first two octets of every cluster link address.
    static let prefix = "10.219"
    private static let validOctets: ClosedRange<UInt8> = 1...254

    let third: UInt8
    let fourth: UInt8

    var dottedDecimal: String { "\(Self.prefix).\(third).\(fourth)" }

    init?(third: UInt8, fourth: UInt8) {
        guard Self.validOctets.contains(third), Self.validOctets.contains(fourth) else { return nil }
        self.third = third
        self.fourth = fourth
    }

    /// Strict reader for the isolation record: canonical decimal octets only.
    init?(dottedDecimal: String) {
        let octets = dottedDecimal.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, "\(octets[0]).\(octets[1])" == Self.prefix,
              let third = Self.canonicalOctet(octets[2]), let fourth = Self.canonicalOctet(octets[3]) else { return nil }
        self.init(third: third, fourth: fourth)
    }

    /// The same Mac and port always get the same address: the host part the
    /// first version derives, in this subnet.
    static func derived(machineIdentifier: String, interface: String) -> ClusterLinkClusterAddress {
        let linkLocal = ClusterLinkLocalAddress.derived(machineIdentifier: machineIdentifier, interface: interface)
        // Both octets of a derived link-local address are already in range.
        return ClusterLinkClusterAddress(third: linkLocal.third, fourth: linkLocal.fourth)!
    }

    /// Whether a dotted-decimal IPv4 address, or the destination column of a
    /// route (`10.219`, `10.219.4/24`, `10.219.4.7`), lies in the cluster subnet.
    static func inSubnet(_ text: Substring) -> Bool {
        let address = text.split(separator: "/").first ?? text
        return address == Substring(prefix) || address.hasPrefix(prefix + ".")
    }

    private static func canonicalOctet(_ text: Substring) -> UInt8? {
        let digits = text.utf8
        guard (1...3).contains(digits.count), digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              digits.count == 1 || digits.first != UInt8(ascii: "0") else { return nil }
        return UInt8(text)
    }
}
