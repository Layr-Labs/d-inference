import Foundation

/// Names of network services and hardware ports as Darkbloom will put them in
/// a privileged command: inside single quotes, inside an AppleScript string.
/// Anything outside this character set is never placed in a command.
enum ClusterLinkServiceName {
    /// macOS caps service names well below this.
    private static let maximumBytes = 64

    /// Letters, digits, spaces and `( ) - . _`, starting with a letter or a
    /// digit and ending without a space: no quote, backslash, `$`, backtick
    /// or other character a shell or AppleScript would interpret.
    static func isSafe(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard (1...maximumBytes).contains(bytes.count), let first = bytes.first, let last = bytes.last,
              isLetterOrDigit(first), last != UInt8(ascii: " ") else { return false }
        return bytes.allSatisfy { isLetterOrDigit($0) || " ()-._".utf8.contains($0) }
    }

    /// The one network service Darkbloom creates for a cluster port. The name
    /// says what it is in System Settings → Network and is how Darkbloom
    /// recognises its own service, also where its record is gone.
    static func cluster(interface: String) -> String {
        "Darkbloom Cluster Link (\(interface))"
    }

    /// The interface a service name of Darkbloom's names, if it is one.
    static func clusterInterface(ofService name: String) -> String? {
        let prefix = "Darkbloom Cluster Link (", suffix = ")"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let interface = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        return ClusterLinkName.isInterface(interface) ? interface : nil
    }

    private static func isLetterOrDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }
}

/// Pure readers for the tools that say how a Mac's network is put together
/// around its cluster port. They keep names and yes/no facts; an address
/// leaves a reader only as the answer to "is it this one" or "is it in the
/// cluster subnet".
enum ClusterLinkNetworkFacts {
    struct Service: Equatable, Sendable {
        let name: String
        /// Nil for a service without an interface, such as a VPN.
        let interface: String?
        let enabled: Bool
    }

    /// One network service's configuration as `networksetup -getinfo` prints it.
    struct ServiceInfo: Equatable, Sendable {
        let manual: Bool
        let address: String?
        let subnetMask: String?
        /// A router is configured or was learned.
        let router: Bool
        /// The IPv6 method, lowercased: "automatic", "off", a link-local wording, ...
        let ipv6: String?
    }

    /// `networksetup -listallhardwareports`: interface name to hardware port
    /// name, for interfaces with a valid name.
    static func hardwarePorts(_ text: String) -> [String: String] {
        var ports = [String: String](), port: String?
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("Hardware Port: ") {
                port = String(line.dropFirst("Hardware Port: ".count))
            } else if line.hasPrefix("Device: "), let name = port {
                let device = String(line.dropFirst("Device: ".count))
                if ClusterLinkName.isInterface(device), ports[device] == nil { ports[device] = name }
                port = nil
            }
        }
        return ports
    }

    /// `networksetup -listnetworkserviceorder`. Nil when the text has none of
    /// the shape: a service line `(1) Name` or `(*) Name` followed by its
    /// `(Hardware Port: ..., Device: en7)` line.
    static func services(_ text: String) -> [Service]? {
        var services = [Service](), pending: (name: String, enabled: Bool)?
        var sawHeader = false
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("(Hardware Port: "), line.hasSuffix(")"), let service = pending {
                let body = line.dropFirst().dropLast()
                var interface: String?
                if let marker = body.range(of: ", Device: ", options: .backwards) {
                    let device = String(body[marker.upperBound...])
                    interface = ClusterLinkName.isInterface(device) ? device : nil
                }
                services.append(Service(name: service.name, interface: interface, enabled: service.enabled))
                pending = nil
            } else if line.hasPrefix("("), let close = line.firstIndex(of: ")") {
                let marker = line[line.index(after: line.startIndex)..<close]
                guard marker == "*" || (!marker.isEmpty && marker.allSatisfy(\.isNumber)) else { continue }
                let name = line[line.index(after: close)...].drop { $0 == " " }
                pending = name.isEmpty ? nil : (String(name), marker != "*")
            } else if line.hasPrefix("An asterisk (*) denotes") {
                sawHeader = true
            }
        }
        return sawHeader || !services.isEmpty ? services : nil
    }

    /// `plutil -extract VirtualNetworkInterfaces.Bridge json`: each bridge in
    /// macOS's network preferences and its members, in order. Nil when the
    /// text is not that JSON or names an invalid interface.
    static func preferenceBridges(_ text: String) -> [String: [String]]? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        var bridges = [String: [String]]()
        for (name, value) in object {
            guard ClusterLinkName.isInterface(name), let bridge = value as? [String: Any] else { return nil }
            guard let members = bridge["Interfaces"] else {
                bridges[name] = []
                continue
            }
            guard let names = members as? [String], names.allSatisfy(ClusterLinkName.isInterface) else { return nil }
            bridges[name] = names
        }
        return bridges
    }

    /// `plutil -extract NAT.Enabled raw`: `1` or `true` when Internet Sharing
    /// is on. Nil for anything that is not one of the four plain answers.
    static func sharingEnabled(_ text: String) -> Bool? {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1", "true": return true
        case "0", "false": return false
        default: return nil
        }
    }

    /// `plutil -extract NAT.SharingDevices json`: the devices Internet Sharing
    /// shares to. Names that are not interface names are dropped; nil when
    /// the text is not a JSON array of strings.
    static func sharingDevices(_ text: String) -> [String]? {
        guard let names = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String] else { return nil }
        return names.filter(ClusterLinkName.isInterface)
    }

    /// `netstat -rn -f inet`: the interface of every route whose destination
    /// matches `destination`, in listed order. Nil when the text is not a
    /// route table.
    static func routeInterfaces(_ text: String, where destination: (Substring) -> Bool) -> [String]? {
        var inTable = false, interfaces = [String]()
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: \.isWhitespace)
            if words.first == "Destination", words.dropFirst().first == "Gateway" {
                inTable = true
                continue
            }
            guard inTable, words.count >= 4, destination(words[0]) else { continue }
            let interface = String(words[3])
            if ClusterLinkName.isInterface(interface) { interfaces.append(interface) }
        }
        return inTable ? interfaces : nil
    }

    /// The interfaces that carry a default route.
    static func defaultRouteInterfaces(_ text: String) -> [String]? {
        routeInterfaces(text) { $0 == "default" }
    }

    /// The interfaces that carry a route into the cluster subnet.
    static func clusterSubnetRouteInterfaces(_ text: String) -> [String]? {
        routeInterfaces(text) { ClusterLinkClusterAddress.inSubnet($0) }
    }

    /// `scutil --dns`: the interfaces through which a resolver with at least
    /// one name server is reached, scoped or not. Nil when the text is not a
    /// DNS configuration.
    static func dnsInterfaces(_ text: String) -> [String]? {
        guard text.contains("DNS configuration") else { return nil }
        var interfaces = [String](), hasServer = false, interface: String?
        func close() {
            if hasServer, let interface, !interfaces.contains(interface) { interfaces.append(interface) }
            hasServer = false
            interface = nil
        }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if trimmed.hasPrefix("resolver #") || trimmed.hasPrefix("DNS configuration") {
                close()
            } else if trimmed.hasPrefix("nameserver[") {
                hasServer = true
            } else if trimmed.hasPrefix("if_index"), let open = trimmed.lastIndex(of: "("), trimmed.hasSuffix(")") {
                let name = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
                interface = ClusterLinkName.isInterface(name) ? name : nil
            }
        }
        close()
        return interfaces
    }

    /// `ipconfig getpacket <interface>`: whether the text is the DHCP reply a
    /// lease was taken from.
    static func holdsDHCPLease(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces) == "op = BOOTREPLY" }
    }

    /// `networksetup -getinfo <service>`. Nil when the text has neither
    /// configuration heading.
    static func serviceInfo(_ text: String) -> ServiceInfo? {
        var manual: Bool?, address: String?, mask: String?, router = false, ipv6: String?
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            let key = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            let value = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            switch key {
            case "Manual Configuration" where manual == nil: manual = true
            case "DHCP Configuration" where manual == nil, "BOOTP Configuration" where manual == nil: manual = false
            case "IP address" where address == nil: address = value.isEmpty ? nil : value
            case "Subnet mask" where mask == nil: mask = value.isEmpty ? nil : value
            case "Router": router = router || !(value.isEmpty || value == "(null)" || value == "none")
            case "IPv6" where ipv6 == nil: ipv6 = value.lowercased()
            default: continue
            }
        }
        guard let manual else { return nil }
        return ServiceInfo(manual: manual, address: address, subnetMask: mask, router: router, ipv6: ipv6)
    }

    /// `ifconfig -a`: interfaces other than `except` that carry an IPv4
    /// address in the cluster subnet. Only names leave this function.
    static func interfacesInClusterSubnet(_ text: String, except: String) -> [String] {
        var current: String?, found = [String]()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let first = line.first, first.isWhitespace else {
                current = line.range(of: ": flags=").map { String(line[..<$0.lowerBound]) }
                continue
            }
            let words = line.split(whereSeparator: \.isWhitespace)
            if words.count >= 2, words[0] == "inet", ClusterLinkClusterAddress.inSubnet(words[1]),
               let current, current != except, !found.contains(current) {
                found.append(current)
            }
        }
        return found
    }

    /// `ifconfig -a`: whether `interface` carries exactly this address, from
    /// either version of the link setup.
    static func lists(_ dottedDecimal: String, on interface: String, inListing text: String) -> Bool {
        var inInterface = false
        for line in text.split(whereSeparator: \.isNewline) {
            guard let first = line.first, first.isWhitespace else {
                inInterface = line.hasPrefix(interface + ": flags=")
                continue
            }
            let words = line.split(whereSeparator: \.isWhitespace)
            if inInterface, words.count >= 2, words[0] == "inet", words[1] == dottedDecimal { return true }
        }
        return false
    }
}
