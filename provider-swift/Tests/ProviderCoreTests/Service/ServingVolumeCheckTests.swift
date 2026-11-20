import Foundation
import MachO
import Testing
@testable import ProviderCore

/// A network-serving start runs only when the executable, and every image it
/// loaded from outside the shared cache, sits on the Mac's internal disk.
@Suite struct ServingVolumeCheckTests {
    typealias Volume = ServingVolumeCheck.Volume
    typealias Device = ServingVolumeCheck.Device

    static let internalDisk = Volume(mountPoint: "/System/Volumes/Data", fileSystem: "apfs", local: true,
        removableMount: false, device: Device(isInternal: true, isRemovable: false, isEjectable: false,
                                              isNetwork: false, deviceProtocol: "Apple Fabric", model: "APPLE SSD AP1024Z"))
    static let sealedSystem = Volume(mountPoint: "/", fileSystem: "apfs", local: true, removableMount: false,
                                     device: internalDisk.device)
    // As `statfs` and Disk Arbitration describe an attached `hdiutil` image.
    static let diskImage = Volume(mountPoint: "/Volumes/Darkbloom", fileSystem: "apfs", local: true, removableMount: true,
        device: Device(isInternal: false, isRemovable: true, isEjectable: true, isNetwork: false,
                       deviceProtocol: "Virtual Interface", model: "Disk Image"))

    @Test func theInternalDiskServes() {
        let images = [("/Applications/Darkbloom.app/Contents/MacOS/darkbloom", Self.internalDisk),
                      ("/usr/lib/dyld", Self.sealedSystem)]
        #expect(ServingVolumeCheck.verdict(images.map { ($0.0, Optional($0.1)) }) == .serve)
        var hfs = Self.internalDisk
        hfs.fileSystem = "hfs"
        #expect(ServingVolumeCheck.placement(hfs) == nil)
    }

    @Test func everyOtherVolumeRefuses() {
        var network = Self.internalDisk
        network.local = false
        network.fileSystem = "smbfs"
        network.device = nil
        var flaggedNetwork = Self.internalDisk
        flaggedNetwork.device?.isNetwork = true
        var usbStick = Self.internalDisk
        usbStick.removableMount = true
        usbStick.device = Device(isInternal: false, isRemovable: true, isEjectable: true, isNetwork: false,
                                 deviceProtocol: "USB", model: "Flash Drive")
        var thunderboltSSD = Self.internalDisk
        thunderboltSSD.device = Device(isInternal: false, isRemovable: false, isEjectable: true, isNetwork: false,
                                       deviceProtocol: "PCI-Express", model: "External SSD")
        var fixedExternal = thunderboltSSD
        fixedExternal.device?.isEjectable = false
        var undescribed = Self.internalDisk
        undescribed.device = nil
        var otherFileSystem = Self.internalDisk
        otherFileSystem.fileSystem = "exfat"
        let cases: [(Volume?, ServingVolumeCheck.Placement)] = [
            (network, .networkVolume), (flaggedNetwork, .networkVolume), (Self.diskImage, .diskImage),
            (usbStick, .removableMedia), (thunderboltSSD, .removableMedia), (fixedExternal, .externalDisk),
            (undescribed, .unknown), (otherFileSystem, .unknown), (nil, .unknown),
        ]
        for (volume, placement) in cases {
            #expect(ServingVolumeCheck.placement(volume) == placement, "\(String(describing: volume))")
        }
    }

    @Test func oneImageOffTheInternalDiskRefusesTheProcess() {
        let verdict = ServingVolumeCheck.verdict([
            ("/Applications/Darkbloom.app/Contents/MacOS/darkbloom", Self.internalDisk),
            ("/Volumes/Darkbloom/Frameworks/Extra.framework/Extra", Self.diskImage),
        ])
        #expect(verdict == .refuse(path: "/Volumes/Darkbloom/Frameworks/Extra.framework/Extra",
                                   mountPoint: "/Volumes/Darkbloom", .diskImage))
    }

    @Test func liveImagesStartWithTheMainExecutableAndSkipTheSharedCache() throws {
        let images = ServingVolumeCheck.loadedImagePaths()
        let main = try #require(_dyld_get_image_name(0))
        let resolvedMain = realpath(main, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        }
        #expect(images.first == resolvedMain)
        #expect(images.allSatisfy { !_dyld_shared_cache_contains_path($0) })
        #expect(ServingVolumeCheck.volume(at: "/System/Library")?.local == true)
    }

    @Test func liveFactsReadAnAttachedDiskImageAsOne() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("serving-volume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("volume.dmg").path
        let mount = root.appendingPathComponent("mount").path
        try #require(Self.hdiutil(["create", "-size", "4m", "-fs", "APFS", "-volname", "ServingVolume", image]) == 0)
        try #require(Self.hdiutil(["attach", "-nobrowse", "-noautoopen", "-mountpoint", mount, image]) == 0)
        defer { _ = Self.hdiutil(["detach", mount, "-force"]) }
        let file = mount + "/darkbloom"
        try #require(FileManager.default.createFile(atPath: file, contents: Data("x".utf8)))
        let volume = try #require(ServingVolumeCheck.volume(at: file))
        #expect(ServingVolumeCheck.placement(volume) == .diskImage)
        #expect(ServingVolumeCheck.verdict([(file, volume)])
            == .refuse(path: file, mountPoint: volume.mountPoint, .diskImage))
    }

    private static func hdiutil(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
