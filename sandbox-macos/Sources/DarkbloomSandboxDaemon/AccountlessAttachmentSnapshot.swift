import Darwin
import Foundation

/// Metadata-only preservation check for preexisting attachments. No unrelated
/// image contents are opened and no unrelated device is ever a cleanup target.
struct AccountlessAttachmentSnapshot: Codable, Equatable {
    let attachment: AccountlessAttachedImage
    let image: Node
    let devices: [Device]

    struct Node: Codable, Equatable {
        let device: UInt64
        let inode: UInt64
        let size: UInt64
        let specialDevice: UInt64
        let type: UInt16

        init(path: String, types: [mode_t]) throws {
            var info = stat()
            guard lstat(path, &info) == 0, types.contains(info.st_mode & S_IFMT), info.st_size >= 0 else {
                throw AccountlessDiskError.bindingChanged
            }
            device = UInt64(UInt32(bitPattern: info.st_dev)); inode = UInt64(info.st_ino); size = UInt64(info.st_size)
            specialDevice = UInt64(UInt32(bitPattern: info.st_rdev)); type = UInt16(info.st_mode & S_IFMT)
        }
    }

    struct Device: Codable, Equatable {
        let identifier: AccountlessDiskIdentifier
        let node: Node
        let mount: Node?
    }

    init(_ attachment: AccountlessAttachedImage) throws {
        self.attachment = attachment
        image = try .init(path: attachment.imagePath, types: [S_IFREG, S_IFDIR])
        devices = try attachment.entities.map {
            .init(identifier: $0.device, node: try .init(path: $0.device.nodePath, types: [S_IFBLK]),
                mount: try $0.mountpoint.map { try .init(path: $0, types: [S_IFDIR]) })
        }
    }

    static func requirePreserved(_ baseline: [Self], in current: AccountlessAttachmentInventory, excluding image: URL) throws {
        let others = current.images.filter { !$0.isImage(image) }
        let snapshots = try others.map(Self.init)
        // Extra unrelated attachments are permitted, but cannot replace or
        // reuse any attachment which existed when this operation began.
        for original in baseline {
            guard snapshots.contains(original) else { throw AccountlessDiskError.bindingChanged }
        }
    }
}
