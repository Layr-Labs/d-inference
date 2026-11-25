import DiskArbitration
import Foundation
import MachO
import Testing
@testable import ProviderCore

/// Where the executable, and every image it loaded from outside the shared
/// cache, runs from: the registration reports it, and with refusing on a
/// network-serving start serves only from the Mac's internal disk.
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
        let images: [(path: String, volume: Volume?)] = [
            ("/Applications/Darkbloom.app/Contents/MacOS/darkbloom", Self.internalDisk),
            ("/usr/lib/dyld", Self.sealedSystem),
        ]
        #expect(ServingVolumeCheck.verdict(images) == .serve)
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

    @Test func theRegistrationReportsWhereItRunsFrom() throws {
        let reports: [(ServingVolumeCheck.Verdict, String)] = [
            (.serve, "internal"),
            (.refuse(path: "/x", mountPoint: "/x", .networkVolume), "network"),
            (.refuse(path: "/x", mountPoint: "/x", .diskImage), "disk_image"),
            (.refuse(path: "/x", mountPoint: "/x", .removableMedia), "removable"),
            (.refuse(path: "/x", mountPoint: "/x", .externalDisk), "external"),
            (.refuse(path: "/x", mountPoint: nil, .unknown), "unknown"),
        ]
        for (verdict, reported) in reports {
            #expect(verdict.reportedClass == reported)
            let capabilities = ProviderLoop.registrationPrivacyCapabilities(nil, servingVolume: verdict)
            let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(capabilities)) as? [String: Any])
            #expect(object["serving_volume"] as? String == reported)
        }
        // Older coordinators read the rest as before; a report without it still decodes.
        let older = try JSONDecoder().decode(PrivacyCapabilities.self, from: Data(
            #"{"text_backend_inprocess":true,"text_proxy_disabled":true,"sip_enabled":true,"anti_debug_enabled":true,"core_dumps_disabled":true,"env_scrubbed":true}"#.utf8))
        #expect(older.servingVolume == nil)
    }

    @Test func refusingIsOptIn() {
        #expect(!ServingVolumeCheck.refuses(environment: [:]))
        for on in ["refuse", "1", "on", "true", "REFUSE"] {
            #expect(ServingVolumeCheck.refuses(environment: [ServingVolumeCheck.environmentKey: on]), "\(on)")
        }
        for other in ["report", "0", "off", "false", "", "maybe"] {
            #expect(!ServingVolumeCheck.refuses(environment: [ServingVolumeCheck.environmentKey: other]), "\(other)")
        }
        // The background service reads it from its LaunchAgent.
        #expect(LaunchAgent.passthroughEnvKeys.contains(ServingVolumeCheck.environmentKey))
    }

    @Test func liveImagesStartWithTheMainExecutableAndSkipTheSharedCache() throws {
        let images = ServingVolumeCheck.loadedImages()
        let main = try #require(_dyld_get_image_name(0))
        #expect(images.first?.name == String(cString: main))
        #expect(images.allSatisfy { !_dyld_shared_cache_contains_path($0.name) })
        // The main executable's mapped file is on the file system its path names.
        let mapped = try #require(images.first.flatMap { ServingVolumeCheck.mappedFile(at: $0.header) })
        var named = statfs()
        try #require(statfs(main, &named) == 0)
        #expect(mapped.path != nil)
        #expect(mapped.fileSystem.val.0 == named.f_fsid.val.0 && mapped.fileSystem.val.1 == named.f_fsid.val.1)
        #expect(ServingVolumeCheck.volume(at: "/System/Library")?.local == true)
        // Memory that maps no file has none.
        let anonymous = try #require(mmap(nil, 4096, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0))
        defer { munmap(anonymous, 4096) }
        #expect(ServingVolumeCheck.mappedFile(at: anonymous) == nil)
    }

    /// An attached disk image reads as one, and a file mapped from it still
    /// reads as one after its path changes.
    @Test func aFileMappedFromADiskImageReadsAsOneWhateverItsPathSaysLater() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("serving-volume-\(UUID().uuidString)").path
        let parent = root + "/q", renamed = root + "/q.old", mount = parent + "/mnt", image = root + "/volume.dmg"
        try fileManager.createDirectory(atPath: parent, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(atPath: root) }
        try #require(Self.hdiutil(["create", "-size", "4m", "-fs", "APFS", "-volname", "ServingVolume", image]) == 0)
        try #require(Self.hdiutil(["attach", "-nobrowse", "-noautoopen", "-mountpoint", mount, image]) == 0)
        defer {
            // Disk Arbitration unmounts by the path it mounted at: put it back first.
            if fileManager.fileExists(atPath: renamed) {
                try? fileManager.removeItem(atPath: parent)
                try? fileManager.moveItem(atPath: renamed, toPath: parent)
            }
            Self.detach(mount)
        }
        let file = mount + "/darkbloom"
        try #require(fileManager.createFile(atPath: file, contents: Data(repeating: 1, count: 4096)))
        let volume = try #require(ServingVolumeCheck.volume(at: file))
        #expect(ServingVolumeCheck.placement(volume) == .diskImage)
        #expect(ServingVolumeCheck.verdict([(file, volume)])
            == .refuse(path: file, mountPoint: volume.mountPoint, .diskImage))

        let descriptor = open(file, O_RDONLY)
        try #require(descriptor >= 0)
        let mapping = mmap(nil, 4096, PROT_READ, MAP_SHARED, descriptor, 0)
        close(descriptor)
        let address = try #require(mapping == MAP_FAILED ? nil : mapping)
        defer { munmap(address, 4096) }

        try fileManager.moveItem(atPath: parent, toPath: renamed)
        try fileManager.createDirectory(atPath: mount, withIntermediateDirectories: true)
        try #require(fileManager.createFile(atPath: file, contents: Data("x".utf8)))
        #expect(ServingVolumeCheck.placement(ServingVolumeCheck.volume(at: file)) != .diskImage)

        let mapped = try #require(ServingVolumeCheck.mappedFile(at: address))
        #expect(mapped.path?.hasSuffix("/q.old/mnt/darkbloom") == true, "\(String(describing: mapped.path))")
        let mappedVolume = ServingVolumeCheck.volume(fileSystem: mapped.fileSystem, session: DASessionCreate(kCFAllocatorDefault))
        #expect(ServingVolumeCheck.placement(mappedVolume) == .diskImage)
    }

    private static func detach(_ mount: String) {
        for attempt in 1 ... 3 {
            if hdiutil(["detach", mount, "-force"]) == 0 { return }
            if attempt < 3 { Thread.sleep(forTimeInterval: 1) }
        }
        Issue.record("\(mount) is still attached")
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
