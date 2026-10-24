import Darwin
import Foundation

/// A filesystem suitability check, never a certification of device firmware.
public struct CacheVolume: Sendable, Encodable {
    public let directory: String
    public let uuid: String
    public let internalVolume: Bool
    public let encryptedVolume: Bool

    public static func inspect(directory: String) throws -> CacheVolume {
        let expanded = (directory as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), !expanded.utf8.contains(0),
              !expanded.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw CacheStorageError("Use an absolute directory without traversal components.")
        }
        let url = URL(fileURLWithPath: CacheStorage.canonicalPath(expanded), isDirectory: true)
        // Selection may replace a stale pin. Still refuse every symlink.
        let fd: Int32
        do {
            fd = try SSDNoFollowIO.openDirectoryChain(url, enforceCacheVolume: false)
        } catch let error as SSDBlockStoreError {
            throw CacheStorageError("Cannot open cache directory: \(error.description)")
        }
        defer { close(fd) }
        let uuid = try validateDescriptor(fd)
        try CacheDirectoryPermissions.validate(fd)
        guard access(url.path, W_OK | X_OK) == 0 else {
            throw CacheStorageError("Choose a writable directory owned by you, without group or other write permission (for example, mkdir -m 700 on the mounted disk).")
        }
        let protection = try CacheVolumeProtection.inspect(fd, expectedUUID: uuid)
        return CacheVolume(directory: url.path, uuid: uuid,
                           internalVolume: protection.internalVolume,
                           encryptedVolume: protection.encryptedVolume)
    }

    /// Read the identity from the opened directory, not a racy pathname query.
    static func validateDescriptor(_ fd: Int32) throws -> String {
        var filesystem = statfs()
        guard fstatfs(fd, &filesystem) == 0 else {
            throw CacheStorageError("Cannot inspect the mounted cache filesystem.")
        }
        let capacity = MemoryLayout.size(ofValue: filesystem.f_fstypename)
        let kind = withUnsafePointer(to: &filesystem.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
        try validateFilesystem(kind: kind, flags: filesystem.f_flags)
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_UUID)
        var buffer = [UInt8](repeating: 0, count: 20) // uint32 length + uuid_t (packed)
        let result = buffer.withUnsafeMutableBytes {
            fgetattrlist(fd, &attributes, $0.baseAddress, $0.count, 0)
        }
        guard result == 0 else { throw CacheStorageError("Cannot read cache volume UUID.") }
        let uuid = buffer.withUnsafeBufferPointer {
            NSUUID(uuidBytes: $0.baseAddress!.advanced(by: 4)).uuidString.lowercased()
        }
        guard uuid != "00000000-0000-0000-0000-000000000000" else {
            throw CacheStorageError("The cache volume has no stable UUID.")
        }
        return uuid
    }

    static func validateFilesystem(kind: String, flags: UInt32) throws {
        guard kind == "apfs", flags & UInt32(MNT_LOCAL) != 0,
              flags & UInt32(MNT_RDONLY | MNT_IGNORE_OWNERSHIP) == 0 else {
            throw CacheStorageError("Cache storage requires a local, writable APFS volume with ownership enabled. Network, exFAT and ownership-ignored volumes are refused.")
        }
    }

    static func validateEncryption(internalVolume: Bool, encryptedVolume: Bool) throws {
        guard internalVolume || encryptedVolume else {
            throw CacheStorageError("External cache volumes must use APFS (Encrypted). Encrypt the volume in Disk Utility before selecting it.")
        }
    }
}

struct CacheStorageError: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}
