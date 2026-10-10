import Foundation
import Darwin

/// What the approval of link setup v2 changed for each cluster port: the
/// address it gave the port, where the port sat in a bridge, and which
/// services it switched off. `--remove` puts exactly that back. Written
/// before the prompt, so nothing can exist that a removal does not know of.
/// It holds an address, so it is an owner-only file read with the strict
/// cluster file policy, like the first version's alias record.
struct ClusterLinkIsolationRecord: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let interface: String
        let address: ClusterLinkClusterAddress
        let hardwarePort: String
        /// The bridge the port was taken out of, and its position there.
        let bridge: ClusterLinkIsolationPlan.BridgeSlot?
        /// Services that were enabled on the port and were switched off.
        let disabledServices: [String]
    }

    static let schemaName = "darkbloom_cluster_link_isolation_v1"
    static let maximumBytes = 16 * 1024

    /// At most one entry per interface.
    var entries = [Entry]()

    func entry(on interface: String) -> Entry? {
        entries.first { $0.interface == interface }
    }

    /// Records `entry`, keeping what an earlier, unfinished attempt recorded
    /// about the state before Darkbloom: the first bridge position seen and
    /// every service switched off.
    mutating func set(_ entry: Entry) {
        let earlier = self.entry(on: entry.interface)
        forget(interface: entry.interface)
        var disabled = earlier?.disabledServices ?? []
        for service in entry.disabledServices where !disabled.contains(service) { disabled.append(service) }
        entries.append(Entry(interface: entry.interface, address: entry.address, hardwarePort: entry.hardwarePort,
            bridge: earlier?.bridge ?? entry.bridge, disabledServices: disabled))
    }

    mutating func forget(interface: String) {
        entries.removeAll { $0.interface == interface }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Wire(entries: entries.map { entry in
            .init(address: entry.address.dottedDecimal, bridge: entry.bridge?.bridge, bridgeIndex: entry.bridge?.index,
                disabledServices: entry.disabledServices, hardwarePort: entry.hardwarePort, interface: entry.interface)
        }, schema: Self.schemaName))
    }

    /// Accepts only what `encoded()` writes: validated names, cluster
    /// addresses, one entry per interface; re-encoding must give the same bytes.
    static func decode(_ data: Data) throws -> ClusterLinkIsolationRecord {
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        var record = ClusterLinkIsolationRecord()
        for entry in wire.entries {
            let bridge: ClusterLinkIsolationPlan.BridgeSlot?
            switch (entry.bridge, entry.bridgeIndex) {
            case (let name?, let index?) where ClusterLinkName.isInterface(name) && index >= 0: bridge = .init(bridge: name, index: index)
            case (nil, nil): bridge = nil
            default: throw ClusterConfigurationError.invalid("Link isolation record names an invalid bridge")
            }
            guard ClusterLinkName.isInterface(entry.interface), record.entry(on: entry.interface) == nil,
                  ClusterLinkServiceName.isSafe(entry.hardwarePort),
                  entry.disabledServices.allSatisfy(ClusterLinkServiceName.isSafe),
                  let address = ClusterLinkClusterAddress(dottedDecimal: entry.address) else {
                throw ClusterConfigurationError.invalid("Link isolation record names an invalid interface, service or address")
            }
            record.entries.append(.init(interface: entry.interface, address: address, hardwarePort: entry.hardwarePort,
                bridge: bridge, disabledServices: entry.disabledServices))
        }
        guard wire.schema == schemaName, try record.encoded() == data else {
            throw ClusterConfigurationError.invalid("Link isolation record is not canonical")
        }
        return record
    }

    private struct Wire: Codable {
        struct Entry: Codable {
            let address: String
            let bridge: String?
            let bridgeIndex: Int?
            let disabledServices: [String]
            let hardwarePort: String
            let interface: String

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(address, forKey: .address)
                try container.encodeIfPresent(bridge, forKey: .bridge)
                try container.encodeIfPresent(bridgeIndex, forKey: .bridgeIndex)
                try container.encode(disabledServices, forKey: .disabledServices)
                try container.encode(hardwarePort, forKey: .hardwarePort)
                try container.encode(interface, forKey: .interface)
            }
        }
        let entries: [Entry]
        let schema: String
    }
}

struct ClusterLinkIsolationStore {
    let paths: ClusterUserPaths

    /// An absent file is an empty record. An unsafe or malformed one is an error.
    func load() throws -> ClusterLinkIsolationRecord {
        let file = paths.linkIsolationRecordFile
        var metadata = stat()
        if lstat(file.path, &metadata) != 0, errno == ENOENT { return ClusterLinkIsolationRecord() }
        return try .decode(ClusterConfigurationFiles.read(file, maximum: ClusterLinkIsolationRecord.maximumBytes, privateMode: true))
    }

    /// Applies `change` to the record as it is on disk, under the file lock.
    func update(_ change: (inout ClusterLinkIsolationRecord) -> Void) throws {
        _ = try load()
        let directory = try ClusterConfigurationFiles.directory(paths.deviceDirectory, create: true, privateMode: true)
        Darwin.close(directory.descriptor)
        try ClusterConfigurationFiles.update(paths.linkIsolationRecordFile, maximum: ClusterLinkIsolationRecord.maximumBytes) { current in
            var record = try current.map(ClusterLinkIsolationRecord.decode) ?? ClusterLinkIsolationRecord()
            change(&record)
            return try record.encoded()
        }
    }
}
