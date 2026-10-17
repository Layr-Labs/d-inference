import Foundation
import Darwin

/// The aliases `cluster link --fix` has added and not yet removed. `--remove`
/// acts only on what this names. It holds addresses, so it lives in an
/// owner-only file and is read with the strict cluster file policy.
struct ClusterLinkAliasRecord: Equatable, Sendable {
    struct Alias: Equatable, Sendable {
        let interface: String
        let address: ClusterLinkLocalAddress
    }

    static let schemaName = "darkbloom_cluster_link_alias_v1"
    static let maximumBytes = 4096

    /// At most one alias per interface.
    var aliases = [Alias]()

    func alias(on interface: String) -> Alias? {
        aliases.first { $0.interface == interface }
    }

    mutating func set(_ alias: Alias) {
        forget(interface: alias.interface)
        aliases.append(alias)
    }

    mutating func forget(interface: String) {
        aliases.removeAll { $0.interface == interface }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Wire(
            aliases: aliases.map { .init(address: $0.address.dottedDecimal, interface: $0.interface) }, schema: Self.schemaName))
    }

    /// Accepts only what `encoded()` writes: validated names and link-local
    /// addresses, one alias per interface. The exact re-encoding comparison
    /// also rejects unknown fields and trailing data.
    static func decode(_ data: Data) throws -> ClusterLinkAliasRecord {
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        var record = ClusterLinkAliasRecord()
        for alias in wire.aliases {
            guard ClusterLinkName.isInterface(alias.interface), record.alias(on: alias.interface) == nil,
                  let address = ClusterLinkLocalAddress(dottedDecimal: alias.address) else {
                throw ClusterConfigurationError.invalid("Link alias record names an invalid interface or address")
            }
            record.aliases.append(.init(interface: alias.interface, address: address))
        }
        guard wire.schema == schemaName, try record.encoded() == data else {
            throw ClusterConfigurationError.invalid("Link alias record is not canonical")
        }
        return record
    }

    private struct Wire: Codable {
        struct Alias: Codable {
            let address: String
            let interface: String
        }
        let aliases: [Alias]
        let schema: String
    }
}

struct ClusterLinkAliasStore {
    let paths: ClusterUserPaths

    /// An absent file is an empty record. An unsafe or malformed one is an error.
    func load() throws -> ClusterLinkAliasRecord {
        let file = paths.linkAliasRecordFile
        var metadata = stat()
        if lstat(file.path, &metadata) != 0, errno == ENOENT { return ClusterLinkAliasRecord() }
        return try .decode(ClusterConfigurationFiles.read(file, maximum: ClusterLinkAliasRecord.maximumBytes, privateMode: true))
    }

    /// Applies `change` to the record as it is on disk at that moment, under
    /// the file lock, so two commands cannot lose each other's entries.
    func update(_ change: (inout ClusterLinkAliasRecord) -> Void) throws {
        // Refuses a loose, linked or malformed record before anything replaces it.
        _ = try load()
        // `update` creates a missing directory owner-only but accepts an
        // existing one that others can read; opening it in private mode
        // first refuses that before any address is written.
        let directory = try ClusterConfigurationFiles.directory(paths.deviceDirectory, create: true, privateMode: true)
        Darwin.close(directory.descriptor)
        try ClusterConfigurationFiles.update(paths.linkAliasRecordFile, maximum: ClusterLinkAliasRecord.maximumBytes) { current in
            var record = try current.map(ClusterLinkAliasRecord.decode) ?? ClusterLinkAliasRecord()
            change(&record)
            return try record.encoded()
        }
    }
}
