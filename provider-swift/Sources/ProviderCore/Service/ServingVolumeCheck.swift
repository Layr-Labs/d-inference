import Darwin
import DiskArbitration
import Foundation
import MachO

/// Where the provider's executable, and every other image it loaded from
/// outside the system's shared cache, sits: the Mac's internal disk, or a
/// network file system, removable media, an external disk or a mounted disk
/// image. The facts come from the file the kernel mapped for each image (not
/// the path it was loaded by), the mounted file systems (`getfsstat`) and Disk
/// Arbitration.
///
/// The registration reports the class (`privacy_capabilities.serving_volume`).
/// A release build (`ServiceLaunchCheck.enforcedInThisBuild`) refuses to serve
/// the network off the internal disk only when `DARKBLOOM_SERVING_VOLUME_CHECK`
/// turns refusing on.
public enum ServingVolumeCheck {
    public static let environmentKey = "DARKBLOOM_SERVING_VOLUME_CHECK"

    /// `DARKBLOOM_SERVING_VOLUME_CHECK=refuse` (or `1`, `on`, `true`, in any
    /// case) turns refusing on. Unset or anything else, the provider serves
    /// and reports where it runs from; the report is the same either way.
    public static func refuses(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        switch environment[environmentKey]?.lowercased() {
        case "refuse", "1", "on", "true": true
        default: false
        }
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

        /// The registration's `serving_volume`.
        public var reportedClass: String {
            switch self {
            case .serve: "internal"
            case .refuse(_, _, .networkVolume): "network"
            case .refuse(_, _, .diskImage): "disk_image"
            case .refuse(_, _, .removableMedia): "removable"
            case .refuse(_, _, .externalDisk): "external"
            case .refuse(_, _, .unknown): "unknown"
            }
        }
    }

    /// This process's verdict, read once on first use.
    public static let liveAtStart: Verdict = live()

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

    /// This process's verdict from the files mapped for its loaded images.
    public static func live() -> Verdict {
        let session = DASessionCreate(kCFAllocatorDefault)
        return verdict(loadedImages().map { image in
            let mapped = mappedFile(at: image.header)
            return (mapped?.path ?? image.name, mapped.flatMap { volume(fileSystem: $0.fileSystem, session: session) })
        })
    }

    /// An image dyld loaded: the path it was loaded by and its Mach-O header.
    struct LoadedImage {
        var name: String
        var header: UnsafeRawPointer
    }

    /// The main executable and every other image dyld loaded from outside the
    /// shared cache (the shared cache is part of the sealed system volume).
    static func loadedImages() -> [LoadedImage] {
        var images: [LoadedImage] = []
        for index in 0 ..< _dyld_image_count() {
            guard let name = _dyld_get_image_name(index), let header = _dyld_get_image_header(index) else { continue }
            if index != 0, _dyld_shared_cache_contains_path(name) { continue }
            images.append(LoadedImage(name: String(cString: name), header: UnsafeRawPointer(header)))
        }
        return images
    }

    /// The file the kernel mapped at an address in this process.
    struct MappedFile {
        /// The kernel's current path for the file; nil when it has none.
        var path: String?
        /// The file system the file is on (`statfs`'s `f_fsid`).
        var fileSystem: fsid_t
    }

    /// The file mapped at `address`; nil when no file on a mounted file system is.
    static func mappedFile(at address: UnsafeRawPointer) -> MappedFile? {
        var info = proc_regionwithpathinfo()
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        let target = UInt64(UInt(bitPattern: address))
        guard proc_pidinfo(getpid(), PROC_PIDREGIONPATHINFO, target, &info, size) == size else { return nil }
        // When no region holds the address, the kernel describes the next one.
        let region = info.prp_prinfo
        guard region.pri_address <= target, target - region.pri_address < region.pri_size else { return nil }
        let fileSystem = info.prp_vip.vip_vi.vi_fsid
        guard fileSystem.val.0 != 0 || fileSystem.val.1 != 0 else { return nil }
        let path = text(info.prp_vip.vip_path)
        return MappedFile(path: path.isEmpty ? nil : path, fileSystem: fileSystem)
    }

    /// The volume `path` is on; nil when `statfs` fails.
    static func volume(at path: String, session: DASession? = DASessionCreate(kCFAllocatorDefault)) -> Volume? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        return volume(fs, session: session)
    }

    /// The mounted volume whose file system is `fileSystem`; nil when none is.
    static func volume(fileSystem: fsid_t, session: DASession?) -> Volume? {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return nil }
        var mounts = Array(repeating: statfs(), count: Int(count) + 4)
        let filled = mounts.withUnsafeMutableBufferPointer { buffer in
            getfsstat(buffer.baseAddress, Int32(buffer.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        guard filled > 0 else { return nil }
        return mounts.prefix(Int(filled))
            .first { $0.f_fsid.val.0 == fileSystem.val.0 && $0.f_fsid.val.1 == fileSystem.val.1 }
            .map { volume($0, session: session) }
    }

    private static func volume(_ fs: statfs, session: DASession?) -> Volume {
        Volume(mountPoint: text(fs.f_mntonname), fileSystem: text(fs.f_fstypename),
               local: fs.f_flags & UInt32(MNT_LOCAL) != 0,
               removableMount: fs.f_flags & UInt32(MNT_REMOVABLE) != 0,
               device: device(source: text(fs.f_mntfromname), session: session))
    }

    /// A fixed-size C string field as text.
    private static func text<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
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
