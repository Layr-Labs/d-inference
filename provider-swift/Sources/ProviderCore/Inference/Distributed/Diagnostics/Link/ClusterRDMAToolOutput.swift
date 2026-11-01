import Foundation
import Darwin

/// Pure readers for the text printed by `rdma_ctl status` and `ibv_devinfo`.
/// They keep names and yes/no facts; GUIDs, GIDs and addresses are never
/// returned.
enum ClusterRDMAToolOutput {
    enum ControlState: Equatable, Sendable { case enabled, disabled }

    struct Device: Equatable, Sendable {
        let name: String
        let transport: ClusterLinkReadinessReport.Transport
        let portActive: Bool
    }

    /// Nil unless the whole text is exactly one of the two known words.
    static func controlState(_ text: String) -> ControlState? {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "enabled": return .enabled
        case "disabled": return .disabled
        default: return nil
        }
    }

    /// The devices of an `ibv_devinfo` listing, plain or verbose, in printed
    /// order. Nil when no device is recognized or a name is malformed or
    /// repeated. JACCL addresses port 1, so a device's first port state decides.
    static func devices(_ text: String) -> [Device]? {
        struct Block {
            let name: String
            var transport = ClusterLinkReadinessReport.Transport.other
            var portActive: Bool?
        }
        var blocks = [Block]()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let (key, value) = field(line) else { continue }
            if key == "hca_id" {
                guard ClusterLinkName.isDevice(value), !blocks.contains(where: { $0.name == value }) else { return nil }
                blocks.append(Block(name: value))
            } else if key == "transport", !blocks.isEmpty {
                blocks[blocks.count - 1].transport = value.hasPrefix("Thunderbolt") ? .thunderbolt : .other
            } else if key == "state", !blocks.isEmpty, blocks[blocks.count - 1].portActive == nil {
                blocks[blocks.count - 1].portActive = value.hasPrefix("PORT_ACTIVE")
            }
        }
        guard !blocks.isEmpty else { return nil }
        return blocks.map { Device(name: $0.name, transport: $0.transport, portActive: $0.portActive ?? false) }
    }

    /// Whether the GID table in `ibv_devinfo -v -d <device>` text holds an
    /// IPv4-mapped entry. Nil when the text does not describe exactly that
    /// device. The GID itself is discarded.
    static func ipv4MappedGIDPresent(inDetail text: String, of device: String) -> Bool? {
        guard devices(text)?.map(\.name) == [device] else { return nil }
        return text.split(whereSeparator: \.isNewline).contains { line in
            guard let (key, value) = field(line), key.hasPrefix("GID[") else { return false }
            return isIPv4Mapped(value)
        }
    }

    private static func field(_ line: Substring) -> (key: String, value: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        return (line[..<colon].trimmingCharacters(in: .whitespaces),
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    /// The same `::ffff:0:0/96` test JACCL applies to each GID.
    private static func isIPv4Mapped(_ gid: String) -> Bool {
        var address = in6_addr()
        guard inet_pton(AF_INET6, gid, &address) == 1 else { return false }
        return withUnsafeBytes(of: address) { bytes in
            bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
        }
    }
}
