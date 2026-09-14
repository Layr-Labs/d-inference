import Foundation

/// Whole image -> one main APFS physical partition -> synthesized container ->
/// one Data role volume. Names such as "Data" or "Macintosh HD" confer no authority.
struct AccountlessAPFSVolumeBinding: Codable, Equatable, Sendable {
    let wholeDisk: AccountlessDiskIdentifier
    let physicalStore: AccountlessDiskIdentifier
    let container: AccountlessDiskIdentifier
    let dataVolume: AccountlessDiskIdentifier
    let volumeUUID: UUID

    static func physicalStore(in listing: Data, wholeDisk: AccountlessDiskIdentifier) throws -> AccountlessDiskIdentifier {
        let root = try AccountlessDiskPlist.root(listing)
        let disks = try AccountlessDiskPlist.records(root["AllDisksAndPartitions"])
        guard wholeDisk.isWholeDisk, disks.count == 1,
              try AccountlessDiskPlist.disk(disks[0]["DeviceIdentifier"]) == wholeDisk,
              disks[0]["Content"] as? String == "GUID_partition_scheme" else { throw AccountlessDiskError.bindingChanged }
        let partitions = try AccountlessDiskPlist.records(disks[0]["Partitions"])
        let identifiers = try partitions.map { try AccountlessDiskPlist.disk($0["DeviceIdentifier"]) }
        guard Set(identifiers).count == identifiers.count,
              identifiers.allSatisfy({ $0.isDirectPartition(of: wholeDisk) }) else { throw AccountlessDiskError.bindingChanged }
        // Apple_APFS_ISC and Apple_APFS_Recovery are separate physical partitions.
        let main = partitions.filter { $0["Content"] as? String == "Apple_APFS" }
        guard main.count == 1 else { throw AccountlessDiskError.invalidInventory }
        return try AccountlessDiskPlist.disk(main[0]["DeviceIdentifier"])
    }

    static func container(in info: Data, physicalStore: AccountlessDiskIdentifier) throws -> AccountlessDiskIdentifier {
        let root = try AccountlessDiskPlist.root(info)
        guard try AccountlessDiskPlist.disk(root["DeviceIdentifier"]) == physicalStore else { throw AccountlessDiskError.bindingChanged }
        let container = try AccountlessDiskPlist.disk(root["APFSContainerReference"])
        guard container.isWholeDisk else { throw AccountlessDiskError.invalidInventory }
        return container
    }

    static func select(in inventory: Data, wholeDisk: AccountlessDiskIdentifier,
                       physicalStore: AccountlessDiskIdentifier, container: AccountlessDiskIdentifier) throws -> Self {
        guard wholeDisk.isWholeDisk, physicalStore.isDirectPartition(of: wholeDisk),
              container.isWholeDisk, container != wholeDisk else { throw AccountlessDiskError.bindingChanged }
        let root = try AccountlessDiskPlist.root(inventory)
        let containers = try AccountlessDiskPlist.records(root["Containers"])
        guard containers.count == 1,
              try AccountlessDiskPlist.disk(containers[0]["ContainerReference"]) == container else { throw AccountlessDiskError.bindingChanged }
        let stores = try AccountlessDiskPlist.records(containers[0]["PhysicalStores"])
        guard stores.count == 1,
              try AccountlessDiskPlist.disk(stores[0]["DeviceIdentifier"]) == physicalStore else { throw AccountlessDiskError.bindingChanged }
        let volumes = try AccountlessDiskPlist.records(containers[0]["Volumes"])
        var identifiers = Set<AccountlessDiskIdentifier>(), matches: [[String: Any]] = []
        for volume in volumes {
            let identifier = try AccountlessDiskPlist.disk(volume["DeviceIdentifier"])
            guard identifier.isDirectPartition(of: container), identifiers.insert(identifier).inserted,
                  let roles = volume["Roles"] as? [String], roles.count <= 16 else { throw AccountlessDiskError.invalidInventory }
            try AccountlessDiskPlist.requireUnmounted(volume)
            if roles == ["Data"] { matches.append(volume) }
        }
        guard matches.count == 1 else { throw AccountlessDiskError.invalidInventory }
        return .init(wholeDisk: wholeDisk, physicalStore: physicalStore, container: container,
            dataVolume: try AccountlessDiskPlist.disk(matches[0]["DeviceIdentifier"]),
            volumeUUID: try AccountlessDiskPlist.uuid(matches[0]["APFSVolumeUUID"]))
    }

    func requireMounted(_ info: Data, at mountpoint: URL, writable: Bool) throws {
        guard wholeDisk.isWholeDisk, physicalStore.isDirectPartition(of: wholeDisk),
              container.isWholeDisk, container != wholeDisk, dataVolume.isDirectPartition(of: container) else {
            throw AccountlessDiskError.bindingChanged
        }
        let root = try AccountlessDiskPlist.root(info)
        guard root["DeviceNode"] as? String == dataVolume.nodePath,
              try AccountlessDiskPlist.disk(root["DeviceIdentifier"]) == dataVolume,
              try AccountlessDiskPlist.disk(root["APFSContainerReference"]) == container,
              try AccountlessDiskPlist.uuid(root["VolumeUUID"]) == volumeUUID,
              root["FilesystemType"] as? String == "apfs", root["MountPoint"] as? String == mountpoint.path,
              try AccountlessDiskPlist.boolean(root["GlobalPermissionsEnabled"]),
              try AccountlessDiskPlist.boolean(root["Writable"]) == writable else { throw AccountlessDiskError.bindingChanged }
    }
}
