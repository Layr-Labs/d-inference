import CoreFoundation
import Foundation

struct AccountlessAttachmentEntity: Codable, Equatable, Sendable {
    let device: AccountlessDiskIdentifier
    let contentHint: String?
    let mountpoint: String?
}

struct AccountlessAttachedImage: Codable, Equatable, Sendable {
    let imagePath: String
    let ownerUID: UInt32
    let writable: Bool
    let entities: [AccountlessAttachmentEntity]

    var devices: Set<AccountlessDiskIdentifier> { Set(entities.map(\.device)) }

    func isImage(_ image: URL) -> Bool {
        Self.normalizedSystemAlias(imagePath) == Self.normalizedSystemAlias(image.path)
    }

    func requireNoUnexpectedMounts(allowed: URL? = nil) throws {
        for entity in entities {
            if let mount = entity.mountpoint, !mount.isEmpty {
                guard let allowed, Self.normalizedSystemAlias(mount) == Self.normalizedSystemAlias(allowed.path) else {
                    throw AccountlessDiskError.unexpectedMount
                }
            }
        }
    }

    func wholeDisk() throws -> AccountlessDiskIdentifier {
        let candidates = entities.filter { $0.contentHint == "GUID_partition_scheme" }
        guard candidates.count == 1, candidates[0].device.isWholeDisk else { throw AccountlessDiskError.invalidInventory }
        return candidates[0].device
    }

    private static func normalizedSystemAlias(_ path: String) -> String {
        for prefix in ["/tmp", "/var", "/etc"] where path == prefix || path.hasPrefix(prefix + "/") {
            return "/private" + path
        }
        return path
    }
}

struct AccountlessAttachmentInventory: Sendable {
    let images: [AccountlessAttachedImage]

    init(_ data: Data) throws {
        let root = try AccountlessDiskPlist.root(data)
        guard let values = root["images"] as? [[String: Any]], values.count <= 256 else { throw AccountlessDiskError.invalidInventory }
        var images: [AccountlessAttachedImage] = [], paths = Set<String>(), devices = Set<AccountlessDiskIdentifier>()
        for value in values {
            guard let path = value["image-path"] as? String, Self.isAbsolutePath(path), paths.insert(path).inserted,
                  let owner = value["owner-uid"] as? NSNumber, CFGetTypeID(owner) != CFBooleanGetTypeID(),
                  owner.doubleValue >= 0, owner.doubleValue <= Double(UInt32.max),
                  owner.doubleValue.rounded(.towardZero) == owner.doubleValue else { throw AccountlessDiskError.invalidInventory }
            let entities = try Self.entities(value["system-entities"])
            guard devices.isDisjoint(with: entities.map(\.device)) else { throw AccountlessDiskError.invalidInventory }
            devices.formUnion(entities.map(\.device))
            images.append(.init(imagePath: path, ownerUID: owner.uint32Value,
                writable: try AccountlessDiskPlist.boolean(value["writeable"]), entities: entities))
        }
        self.images = images.sorted { $0.imagePath < $1.imagePath }
    }

    func target(_ image: URL, ownerUID: UInt32, writable: Bool) throws -> AccountlessAttachedImage? {
        guard let selected = try ownedTarget(image, ownerUID: ownerUID) else { return nil }
        guard selected.writable == writable else { throw AccountlessDiskError.bindingChanged }
        return selected
    }

    func ownedTarget(_ image: URL, ownerUID: UInt32) throws -> AccountlessAttachedImage? {
        let matches = images.filter { $0.isImage(image) }
        guard matches.count <= 1 else { throw AccountlessDiskError.bindingChanged }
        guard let selected = matches.first else { return nil }
        guard selected.ownerUID == ownerUID else { throw AccountlessDiskError.bindingChanged }
        return selected
    }

    static func entities(_ value: Any?) throws -> [AccountlessAttachmentEntity] {
        let entries = try AccountlessDiskPlist.records(value)
        var devices = Set<AccountlessDiskIdentifier>(), result: [AccountlessAttachmentEntity] = []
        for entry in entries {
            guard let node = entry["dev-entry"] as? String, node.hasPrefix("/dev/") else { throw AccountlessDiskError.invalidInventory }
            let device = try AccountlessDiskIdentifier(String(node.dropFirst(5)))
            guard devices.insert(device).inserted else { throw AccountlessDiskError.invalidInventory }
            let hint: String?
            // Attach maps known GUIDs to readable labels, while info exposes
            // GUIDs. Prefer attach's canonical value when it is supplied.
            if let value = entry["unmapped-content-hint"] ?? entry["content-hint"] {
                guard let value = value as? String, value.utf8.count <= 128 else { throw AccountlessDiskError.invalidInventory }
                hint = value
            } else { hint = nil }
            let mount: String?
            if let value = entry["mount-point"] {
                guard let value = value as? String, value.isEmpty || isAbsolutePath(value) else { throw AccountlessDiskError.invalidInventory }
                mount = value.isEmpty ? nil : value
            } else { mount = nil }
            result.append(.init(device: device, contentHint: hint, mountpoint: mount))
        }
        return result.sorted { $0.device.rawValue < $1.device.rawValue }
    }

    private static func isAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 4096 && !path.contains("\0")
            && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }
}
