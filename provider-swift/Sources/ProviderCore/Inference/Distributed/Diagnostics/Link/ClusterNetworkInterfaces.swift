import Foundation

/// Pure reader for `ifconfig` text, for one interface or for `ifconfig -a`.
/// It keeps names and yes/no facts; addresses are never returned.
struct ClusterNetworkInterfaces: Equatable, Sendable {
    struct Interface: Equatable, Sendable {
        let name: String
        /// The `UP` flag: the interface is administratively enabled.
        var isUp: Bool
        /// `status: active`: the link itself is up.
        var linkActive = false
        var hasIPv4Address = false
        /// Non-empty only for a bridge interface.
        var bridgeMembers = [String]()
    }

    let interfaces: [Interface]

    /// Nil when the text is not an interface listing: no interface, an
    /// attribute before the first interface, or a malformed name.
    static func parse(_ text: String) -> ClusterNetworkInterfaces? {
        var interfaces = [Interface]()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let first = line.first, first.isWhitespace else {
                guard let interface = header(line) else { return nil }
                interfaces.append(interface)
                continue
            }
            guard !interfaces.isEmpty else { return nil }
            let words = line.split(whereSeparator: \.isWhitespace)
            switch words.first {
            case "inet":
                interfaces[interfaces.count - 1].hasIPv4Address = true
            case "status:":
                interfaces[interfaces.count - 1].linkActive = words.dropFirst().first == "active"
            case "member:":
                guard let member = words.dropFirst().first.map(String.init), ClusterLinkName.isInterface(member) else { return nil }
                interfaces[interfaces.count - 1].bridgeMembers.append(member)
            default:
                continue
            }
        }
        return interfaces.isEmpty ? nil : ClusterNetworkInterfaces(interfaces: interfaces)
    }

    /// Whether `interface` carries exactly this IPv4 address. Nil when the text
    /// is not an interface listing. Only the answer leaves this function.
    static func lists(_ address: ClusterLinkLocalAddress, on interface: String, inListing text: String) -> Bool? {
        guard parse(text) != nil else { return nil }
        var inInterface = false
        for line in text.split(whereSeparator: \.isNewline) {
            guard let first = line.first, first.isWhitespace else {
                inInterface = line.hasPrefix(interface + ": flags=")
                continue
            }
            let words = line.split(whereSeparator: \.isWhitespace)
            if inInterface, words.count >= 2, words[0] == "inet", words[1] == address.dottedDecimal { return true }
        }
        return false
    }

    func interface(named name: String) -> Interface? {
        interfaces.first { $0.name == name }
    }

    func bridge(containing member: String) -> String? {
        interfaces.first { $0.bridgeMembers.contains(member) }?.name
    }

    /// `en7: flags=8863<UP,BROADCAST,RUNNING> mtu 1500`
    private static func header(_ line: Substring) -> Interface? {
        guard let separator = line.range(of: ": flags=") else { return nil }
        let name = String(line[..<separator.lowerBound])
        guard ClusterLinkName.isInterface(name) else { return nil }
        let rest = line[separator.upperBound...]
        guard let open = rest.firstIndex(of: "<"), let close = rest.firstIndex(of: ">"), open < close else { return nil }
        let flags = rest[rest.index(after: open)..<close].split(separator: ",")
        return Interface(name: name, isUp: flags.contains("UP"))
    }
}
