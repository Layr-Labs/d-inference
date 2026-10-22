import Darwin
import Foundation
import IOKit
import SystemConfiguration

/// What carries one network interface, as far as the control channel cares.
public enum ClusterLinkInterfaceKind: String, Sendable, Equatable, Codable {
    /// A Thunderbolt IP port (IOKit provider `AppleThunderboltIPPort`).
    case thunderbolt
    /// A bridge whose configured members are all Thunderbolt ports (macOS's
    /// "Thunderbolt Bridge", today's link on the second Mac).
    case thunderboltBridge
    /// Wired Ethernet that is not Thunderbolt (USB or PCIe adapters).
    case wiredEthernet
    case wifi
    case loopback
    /// A bridge whose members are unknown or mixed.
    case bridge
    case other
}

/// Which interfaces may carry the control channel.
public enum ClusterLinkInterfacePolicy: String, Sendable, Equatable, Codable {
    /// Production: a Thunderbolt port, or a bridge made only of Thunderbolt ports.
    case thunderboltOnly
    /// N-Mac fallback edge (`tcp-lan`, PROD-PLAN-NMAC 2.3): Thunderbolt or wired Ethernet.
    case thunderboltOrWired
    /// One-Mac qualification over loopback; refuses every real interface.
    case loopbackForTests
}

/// Why an interface or address is refused. Names only, never an address.
public enum ClusterLinkInterfaceRefusal: Error, Equatable, Sendable {
    case invalidInterfaceName
    case interfaceMissing
    case wifi
    case notThunderbolt(ClusterLinkInterfaceKind)
    case bridgeMembersUnknown
    case bridgeMemberNotThunderbolt
    case loopbackRequiresTestPolicy
    case testPolicyRequiresLoopback
    case noUsableAddress
    case addressNotOnInterface
    case peerNotOnLink
}

/// One IPv4 address on an interface with its netmask (host byte order).
public struct ClusterLinkInterfaceAddress: Sendable, Equatable {
    public let address: ClusterLinkIPv4Address
    public let netmask: UInt32
    public init(address: ClusterLinkIPv4Address, netmask: UInt32) {
        self.address = address; self.netmask = netmask
    }
    public func contains(_ other: ClusterLinkIPv4Address) -> Bool {
        address.value & netmask == other.value & netmask
    }
}

/// Facts about one interface, read once when a listener binds or a client dials.
public struct ClusterLinkInterfaceFacts: Sendable, Equatable {
    public let name: String
    public let index: UInt32
    public let kind: ClusterLinkInterfaceKind
    /// For a bridge: each configured member's kind; nil when not a bridge or unknown.
    public let bridgeMembers: [String: ClusterLinkInterfaceKind]?
    public let addresses: [ClusterLinkInterfaceAddress]

    public init(name: String, index: UInt32, kind: ClusterLinkInterfaceKind,
                bridgeMembers: [String: ClusterLinkInterfaceKind]?, addresses: [ClusterLinkInterfaceAddress]) {
        self.name = name; self.index = index; self.kind = kind
        self.bridgeMembers = bridgeMembers; self.addresses = addresses
    }
}

public protocol ClusterLinkInterfaceInspecting: Sendable {
    func facts(forInterface name: String) throws -> ClusterLinkInterfaceFacts
}

/// The interface, index and local address a socket binds to.
public struct ClusterLinkInterfaceSelection: Sendable, Equatable {
    public let interface: String
    public let index: UInt32
    public let kind: ClusterLinkInterfaceKind
    public let local: ClusterLinkInterfaceAddress
}

public enum ClusterLinkInterfaceAdmission {
    /// Applies the policy, picks the local address and checks the peer is on
    /// the same link. A Wi-Fi interface, or a bridge with a Wi-Fi member, is
    /// refused under every policy.
    public static func select(interface: String, localAddress: ClusterLinkIPv4Address?,
                              peerAddress: ClusterLinkIPv4Address?, policy: ClusterLinkInterfacePolicy,
                              inspector: any ClusterLinkInterfaceInspecting) throws -> ClusterLinkInterfaceSelection {
        guard isInterfaceName(interface) else { throw ClusterLinkInterfaceRefusal.invalidInterfaceName }
        let facts = try inspector.facts(forInterface: interface)
        try admit(facts, policy: policy)
        let local: ClusterLinkInterfaceAddress
        if let localAddress {
            guard let match = facts.addresses.first(where: { $0.address == localAddress }) else {
                throw ClusterLinkInterfaceRefusal.addressNotOnInterface
            }
            local = match
        } else {
            guard let preferred = preferredAddress(facts.addresses, peer: peerAddress) else {
                throw ClusterLinkInterfaceRefusal.noUsableAddress
            }
            local = preferred
        }
        if let peerAddress, policy != .loopbackForTests {
            guard local.contains(peerAddress), peerAddress != local.address else {
                throw ClusterLinkInterfaceRefusal.peerNotOnLink
            }
        }
        return .init(interface: facts.name, index: facts.index, kind: facts.kind, local: local)
    }

    public static func admit(_ facts: ClusterLinkInterfaceFacts, policy: ClusterLinkInterfacePolicy) throws {
        if facts.kind == .wifi || facts.bridgeMembers?.values.contains(.wifi) == true {
            throw ClusterLinkInterfaceRefusal.wifi
        }
        switch policy {
        case .loopbackForTests:
            guard facts.kind == .loopback else { throw ClusterLinkInterfaceRefusal.testPolicyRequiresLoopback }
        case .thunderboltOnly, .thunderboltOrWired:
            switch facts.kind {
            case .thunderbolt, .thunderboltBridge: return
            case .wiredEthernet where policy == .thunderboltOrWired: return
            case .loopback: throw ClusterLinkInterfaceRefusal.loopbackRequiresTestPolicy
            case .bridge:
                guard let members = facts.bridgeMembers, !members.isEmpty else {
                    throw ClusterLinkInterfaceRefusal.bridgeMembersUnknown
                }
                throw ClusterLinkInterfaceRefusal.bridgeMemberNotThunderbolt
            default: throw ClusterLinkInterfaceRefusal.notThunderbolt(facts.kind)
            }
        }
    }

    /// Prefers an address on the peer's subnet; then link setup v2's cluster
    /// subnet; then any other ordinary address (today's Internet Sharing
    /// subnet); link-local last. Deterministic for equal candidates.
    public static func preferredAddress(_ addresses: [ClusterLinkInterfaceAddress],
                                        peer: ClusterLinkIPv4Address?) -> ClusterLinkInterfaceAddress? {
        let usable = addresses.filter { !$0.address.isUnspecified }
        func rank(_ candidate: ClusterLinkInterfaceAddress) -> Int {
            if let peer, candidate.contains(peer), candidate.address != peer { return 0 }
            if candidate.address.isClusterSubnet { return 1 }
            if candidate.address.isLoopback { return 2 }
            if !candidate.address.isLinkLocal { return 3 }
            return 4
        }
        return usable.min { (rank($0), $0.address.value) < (rank($1), $1.address.value) }
    }

    /// The first candidate (a port first, then its bridges) holding an
    /// address on `address`'s subnet; nil when none does.
    public static func carrier(reaching address: ClusterLinkIPv4Address,
                               candidates: [(name: String, addresses: [ClusterLinkInterfaceAddress])]) -> String? {
        candidates.first { candidate in
            candidate.addresses.contains { !$0.address.isUnspecified && $0.contains(address) }
        }?.name
    }

    /// The kernel's interface-name shape: a letter, then letters and digits, at most 15 bytes.
    public static func isInterfaceName(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard (1...15).contains(bytes.count) else { return false }
        func letter(_ b: UInt8) -> Bool { (65...90).contains(b) || (97...122).contains(b) }
        return letter(bytes[0]) && bytes.allSatisfy { letter($0) || (48...57).contains($0) }
    }
}

/// Reads interface facts from the running system: addresses from
/// `getifaddrs`, Wi-Fi from SystemConfiguration, Thunderbolt from the IOKit
/// provider of the BSD interface, bridge members from the network preferences.
public struct ClusterLinkSystemInterfaceInspector: ClusterLinkInterfaceInspecting {
    public init() {}

    public func facts(forInterface name: String) throws -> ClusterLinkInterfaceFacts {
        guard ClusterLinkInterfaceAdmission.isInterfaceName(name) else {
            throw ClusterLinkInterfaceRefusal.invalidInterfaceName
        }
        let index = if_nametoindex(name)
        guard index != 0 else { throw ClusterLinkInterfaceRefusal.interfaceMissing }
        let (addresses, loopback) = Self.addresses(of: name)
        let wifi = Self.wifiInterfaces()
        let kind: ClusterLinkInterfaceKind
        var members: [String: ClusterLinkInterfaceKind]?
        if loopback {
            kind = .loopback
        } else if wifi.contains(name) {
            kind = .wifi
        } else if let configured = Self.bridgeMembers(of: name) {
            var kinds = [String: ClusterLinkInterfaceKind]()
            for member in configured { kinds[member] = Self.memberKind(member, wifi: wifi) }
            members = kinds
            kind = !kinds.isEmpty && kinds.values.allSatisfy({ $0 == .thunderbolt }) ? .thunderboltBridge : .bridge
        } else if name.hasPrefix("bridge") {
            kind = .bridge
        } else {
            kind = Self.memberKind(name, wifi: wifi)
        }
        return .init(name: name, index: index, kind: kind, bridgeMembers: members, addresses: addresses)
    }

    /// The interface that carries IPv4 for a Thunderbolt port: the port itself
    /// (link setup v2, or a port with its own service), else the configured
    /// bridge that contains it and holds an address (today's Thunderbolt
    /// Bridge with Internet Sharing). Nil when neither carries IPv4.
    /// A dial or a listener that knows the leader's link address uses
    /// `carrierInterface(forPort:reaching:)` instead.
    public static func carrierInterface(forPort port: String) -> String? {
        guard ClusterLinkInterfaceAdmission.isInterfaceName(port), if_nametoindex(port) != 0 else { return nil }
        if !addresses(of: port).0.isEmpty { return port }
        for name in configuredBridges(containing: port) where if_nametoindex(name) != 0 && !addresses(of: name).0.isEmpty {
            return name
        }
        return nil
    }

    /// The carrier for a Thunderbolt port that reaches `address` (the other
    /// Mac's link address for a client, this Mac's own for a listener): the
    /// port itself when one of its addresses is on that subnet, else a
    /// configured bridge containing the port with such an address. Today's
    /// second Mac holds only a link-local alias on the port while Internet
    /// Sharing's subnet sits on the bridge: that resolves to the bridge.
    /// Falls back to `carrierInterface(forPort:)`, so admission still names
    /// the refusal when nothing reaches the address.
    public static func carrierInterface(forPort port: String, reaching address: ClusterLinkIPv4Address) -> String? {
        guard ClusterLinkInterfaceAdmission.isInterfaceName(port), if_nametoindex(port) != 0 else { return nil }
        var candidates = [(name: port, addresses: addresses(of: port).0)]
        for name in configuredBridges(containing: port) where if_nametoindex(name) != 0 {
            candidates.append((name: name, addresses: addresses(of: name).0))
        }
        return ClusterLinkInterfaceAdmission.carrier(reaching: address, candidates: candidates) ?? carrierInterface(forPort: port)
    }

    /// Bridges in the network preferences whose configured members include
    /// `port`, by name; read-only.
    private static func configuredBridges(containing port: String) -> [String] {
        guard let preferences = SCPreferencesCreate(nil, "darkbloom-link-control" as CFString, nil),
              let virtual = SCPreferencesGetValue(preferences, "VirtualNetworkInterfaces" as CFString) as? [String: Any],
              let bridges = virtual["Bridge"] as? [String: Any] else { return [] }
        return bridges.keys.sorted().filter { name in
            ClusterLinkInterfaceAdmission.isInterfaceName(name) && bridgeMembers(of: name)?.contains(port) == true
        }
    }

    private static func memberKind(_ name: String, wifi: Set<String>) -> ClusterLinkInterfaceKind {
        if wifi.contains(name) { return .wifi }
        if isThunderboltPort(name) { return .thunderbolt }
        if ethernetInterfaces().contains(name) { return .wiredEthernet }
        return .other
    }

    static func addresses(of name: String) -> ([ClusterLinkInterfaceAddress], Bool) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return ([], false) }
        defer { freeifaddrs(head) }
        var result = [ClusterLinkInterfaceAddress]()
        var loopback = false
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard String(cString: entry.pointee.ifa_name) == name else { continue }
            if entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) != 0 { loopback = true }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = entry.pointee.ifa_netmask else { continue }
            let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            result.append(.init(address: .init(value: value), netmask: netmask))
        }
        return (result, loopback)
    }

    private static func wifiInterfaces() -> Set<String> {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [] }
        var names = Set<String>()
        for interface in all {
            guard let type = SCNetworkInterfaceGetInterfaceType(interface),
                  CFEqual(type, kSCNetworkInterfaceTypeIEEE80211),
                  let bsd = SCNetworkInterfaceGetBSDName(interface) else { continue }
            names.insert(bsd as String)
        }
        return names
    }

    private static func ethernetInterfaces() -> Set<String> {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [] }
        var names = Set<String>()
        for interface in all {
            guard let type = SCNetworkInterfaceGetInterfaceType(interface),
                  CFEqual(type, kSCNetworkInterfaceTypeEthernet),
                  let bsd = SCNetworkInterfaceGetBSDName(interface) else { continue }
            names.insert(bsd as String)
        }
        return names
    }

    /// Members of a bridge defined in the network preferences
    /// (`VirtualNetworkInterfaces.Bridge.<name>.Interfaces`), read-only.
    private static func bridgeMembers(of name: String) -> [String]? {
        guard name.hasPrefix("bridge"),
              let preferences = SCPreferencesCreate(nil, "darkbloom-link-control" as CFString, nil),
              let virtual = SCPreferencesGetValue(preferences, "VirtualNetworkInterfaces" as CFString) as? [String: Any],
              let bridges = virtual["Bridge"] as? [String: Any],
              let bridge = bridges[name] as? [String: Any],
              let members = bridge["Interfaces"] as? [String] else { return nil }
        return members.filter(ClusterLinkInterfaceAdmission.isInterfaceName)
    }

    /// True when the BSD interface's IOKit provider is a Thunderbolt IP port.
    static func isThunderboltPort(_ name: String) -> Bool {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, name) else { return false }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 else {
            return false
        }
        defer { IOObjectRelease(parent) }
        return IOObjectConformsTo(parent, "AppleThunderboltIPPort") != 0
    }
}
