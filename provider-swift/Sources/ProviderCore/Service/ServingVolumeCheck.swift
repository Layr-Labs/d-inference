import Darwin
import DiskArbitration
import Foundation
import MachO

/// Network serving runs only when the provider's executable, and every other
/// image it loaded from outside the system's shared cache, sits on the Mac's
/// internal disk: not on a network file system, removable media or a mounted
/// disk image, whose contents can change or stop reading while the process
/// runs. The facts come from the file system (`statfs`) and Disk Arbitration.
public enum ServingVolumeCheck {
    /// Release builds enforce it; debug builds (tests, development) serve from
    /// any volume as before.
    public static var enforcedInThisBuild: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    /// The volume a file is on, as `statfs` and Disk Arbitration describe it.
    public struct Volume: Equatable, Sendable {
        public var mountPoint: String
        public var fileSystem: String
        /// `MNT_LOCAL`: not a network file system.
        public var local: Bool
        /// `MNT_REMOVABLE`.
        public var removableMount: Bool
        /// Disk Arbitration's description of the device; nil when it has none.
        public var device: Device?

        public init(mountPoint: String, fileSystem: String, local: Bool, removableMount: Bool, device: Device?) {
            self.mountPoint = mountPoint
            self.fileSystem = fileSystem
            self.local = local
            self.removableMount = removableMount
            self.device = device
        }
    }

    public struct Device: Equatable, Sendable {
        public var isInternal: Bool
        public var isRemovable: Bool
        public var isEjectable: Bool
        public var isNetwork: Bool
        public var deviceProtocol: String?
        public var model: String?

        public init(isInternal: Bool, isRemovable: Bool, isEjectable: Bool, isNetwork: Bool,
                    deviceProtocol: String?, model: String?) {
            self.isInternal = isInternal
            self.isRemovable = isRemovable
            self.isEjectable = isEjectable
            self.isNetwork = isNetwork
            self.deviceProtocol = deviceProtocol
            self.model = model
        }

        /// How Disk Arbitration describes a device `hdiutil` attached.
        var isDiskImage: Bool { model == "Disk Image" || deviceProtocol == "Virtual Interface" }
    }

    public enum Placement: Equatable, Sendable {
        case networkVolume
        case diskImage
        case removableMedia
        case externalDisk
        /// The volume could not be read or described.
        case unknown
    }

    public enum Verdict: Equatable, Sendable {
        case serve
        case refuse(path: String, mountPoint: String?, Placement)
    }

    /// Serves only when every image is on an internal, fixed, local APFS or HFS+ volume.
    public static func verdict(_ images: [(path: String, volume: Volume?)]) -> Verdict {
        for (path, volume) in images {
            if let placement = placement(volume) {
                return .refuse(path: path, mountPoint: volume?.mountPoint, placement)
            }
        }
        return .serve
    }

    /// Why a volume does not qualify; nil when it does.
    static func placement(_ volume: Volume?) -> Placement? {
        guard let volume else { return .unknown }
        guard volume.local, volume.device?.isNetwork != true else { return .networkVolume }
        guard let device = volume.device else { return .unknown }
        if device.isDiskImage { return .diskImage }
        if volume.removableMount || device.isRemovable || device.isEjectable { return .removableMedia }
        guard device.isInternal else { return .externalDisk }
        guard ["apfs", "hfs"].contains(volume.fileSystem) else { return .unknown }
        return nil
    }

    /// This process's verdict from its loaded images.
    public static func live() -> Verdict {
        let session = DASessionCreate(kCFAllocatorDefault)
        return verdict(loadedImagePaths().map { ($0, volume(at: $0, session: session)) })
    }

    /// The main executable and every other image dyld loaded from outside the
    /// shared cache (the shared cache is part of the sealed system volume).
    static func loadedImagePaths() -> [String] {
        var paths: [String] = []
        for index in 0 ..< _dyld_image_count() {
            guard let name = _dyld_get_image_name(index) else { continue }
            let path = String(cString: name)
            if index != 0, _dyld_shared_cache_contains_path(name) { continue }
            let resolved = realpath(path, nil).map { pointer in
                defer { free(pointer) }
                return String(cString: pointer)
            } ?? path
            if !paths.contains(resolved) { paths.append(resolved) }
        }
        return paths
    }

    /// The volume `path` is on; nil when `statfs` fails.
    public static func volume(at path: String, session: DASession? = DASessionCreate(kCFAllocatorDefault)) -> Volume? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        let fileSystem = withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let source = withUnsafeBytes(of: fs.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let mountPoint = withUnsafeBytes(of: fs.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return Volume(mountPoint: mountPoint, fileSystem: fileSystem, local: fs.f_flags & UInt32(MNT_LOCAL) != 0,
                      removableMount: fs.f_flags & UInt32(MNT_REMOVABLE) != 0,
                      device: device(source: source, session: session))
    }

    static func device(source: String, session: DASession?) -> Device? {
        guard let session, source.hasPrefix("/dev/"),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, String(source.dropFirst(5))),
              let description = DADiskCopyDescription(disk) as? [String: Any]
        else { return nil }
        func flag(_ key: CFString) -> Bool { (description[key as String] as? Bool) ?? false }
        return Device(isInternal: flag(kDADiskDescriptionDeviceInternalKey),
                      isRemovable: flag(kDADiskDescriptionMediaRemovableKey),
                      isEjectable: flag(kDADiskDescriptionMediaEjectableKey),
                      isNetwork: flag(kDADiskDescriptionVolumeNetworkKey),
                      deviceProtocol: description[kDADiskDescriptionDeviceProtocolKey as String] as? String,
                      model: description[kDADiskDescriptionDeviceModelKey as String] as? String)
    }
}
