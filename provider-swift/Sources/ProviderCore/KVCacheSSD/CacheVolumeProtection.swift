import Darwin
import DiskArbitration
import Foundation

/// Fresh encryption state for the device backing an opened directory. Never
/// resolve a possibly replaced cache pathname to decide which disk to inspect.
struct CacheVolumeProtection {
    let internalVolume: Bool
    let encryptedVolume: Bool

    static func inspect(_ fd: Int32, expectedUUID: String) throws -> Self {
        var filesystem = statfs()
        guard fstatfs(fd, &filesystem) == 0 else {
            throw CacheStorageError("Cannot inspect cache volume encryption.")
        }
        let capacity = MemoryLayout.size(ofValue: filesystem.f_mntfromname)
        let device = withUnsafePointer(to: &filesystem.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, device),
              let values = DADiskCopyDescription(disk) as NSDictionary?,
              let rawUUID = values[kDADiskDescriptionVolumeUUIDKey],
              CFGetTypeID(rawUUID as CFTypeRef) == CFUUIDGetTypeID() else {
            throw CacheStorageError("Cannot establish cache volume identity and encryption state.")
        }
        let uuid = CFUUIDCreateString(nil, (rawUUID as! CFUUID)) as String
        guard uuid.lowercased() == expectedUUID.lowercased() else {
            throw CacheStorageError("Cache volume changed while checking encryption.")
        }
        // DADiskCopyDescription fetches the latest state, rather than using a
        // URL's cached resource values. Unknown classification requires encryption.
        let result = Self(internalVolume: values[kDADiskDescriptionDeviceInternalKey] as? Bool == true,
                          encryptedVolume: values[kDADiskDescriptionMediaEncryptedKey] as? Bool == true)
        try CacheVolume.validateEncryption(internalVolume: result.internalVolume,
                                           encryptedVolume: result.encryptedVolume)
        return result
    }
}
