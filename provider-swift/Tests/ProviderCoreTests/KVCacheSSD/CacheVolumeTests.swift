import Darwin
import Foundation
import Testing
@testable import ProviderCore

@Suite("Encrypted cache volume boundary")
struct CacheVolumeTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("cache-volume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return root
    }

    @Test func localVolumeIsInspectedWithoutCreatingCacheFiles() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try CacheVolume.inspect(directory: root.path)
        #expect(result.directory == CacheStorage.canonicalPath(root.path))
        #expect(UUID(uuidString: result.uuid) != nil)
        #expect(FileManager.default.contents(atPath: root.appendingPathComponent("darkbloom").path) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func symlinkAndMissingDirectoryAreRejectedWithoutFollowingOrCreating() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        for path in [link.path, link.appendingPathComponent("child").path,
                     root.appendingPathComponent("missing/child").path, root.path + "/../escape"] {
            #expect(throws: (any Error).self) { try CacheVolume.inspect(directory: path) }
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path))
    }

    @Test func sharedWritableDirectoryIsRejected() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root.path)
        #expect(throws: (any Error).self) { try CacheVolume.inspect(directory: root.path) }
    }

    @Test func unsuitableFilesystemPropertiesAreRejected() throws {
        try CacheVolume.validateFilesystem(kind: "apfs", flags: UInt32(MNT_LOCAL))
        for (kind, flags) in [("exfat", MNT_LOCAL), ("smbfs", 0), ("apfs", 0),
                              ("apfs", MNT_LOCAL | MNT_RDONLY), ("apfs", MNT_LOCAL | MNT_IGNORE_OWNERSHIP)] {
            #expect(throws: (any Error).self) {
                try CacheVolume.validateFilesystem(kind: kind, flags: UInt32(flags))
            }
        }
        #expect(throws: (any Error).self) {
            try CacheVolume.validateEncryption(internalVolume: false, encryptedVolume: false)
        }
        try CacheVolume.validateEncryption(internalVolume: false, encryptedVolume: true)
    }

    @Test func descriptorPinRefusesReplacementVolumeBeforeIO() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let observed = try CacheVolume.inspect(directory: root.path)
        let fd = try SSDNoFollowIO.openDirectoryChain(root)
        defer { close(fd) }
        let settings = CacheSettings(directory: root.path, volumeUUID: observed.uuid)
        try CacheStorage.validateOpenedDirectory(fd, at: root, configuration: settings)
        let replaced = CacheSettings(directory: root.path, volumeUUID: UUID().uuidString)
        #expect(throws: (any Error).self) {
            try CacheStorage.validateOpenedDirectory(fd, at: root, configuration: replaced)
        }
        #expect(throws: (any Error).self) {
            try CacheStorage.validateCreation(at: root, configuration: settings)
        }
        #expect(throws: (any Error).self) {
            try CacheStorage.validateCreation(at: root.deletingLastPathComponent(), configuration: settings)
        }
        try CacheStorage.validateCreation(at: root.appendingPathComponent("darkbloom"), configuration: settings)
    }

    @Test func activeIORechecksEncryptionWithAnUnchangedVolumeIdentity() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = try CacheVolume.inspect(directory: root.path)
        let fd = try SSDNoFollowIO.openDirectoryChain(root)
        defer { close(fd) }
        let settings = CacheSettings(directory: selected.directory, volumeUUID: selected.uuid)
        try CacheStorage.validateOpenedDirectory(fd, at: root, configuration: settings,
            protectionReader: { observedFD, uuid in
                #expect(observedFD == fd && uuid == selected.uuid)
                return CacheVolumeProtection(internalVolume: false, encryptedVolume: true)
            })
        #expect(throws: (any Error).self) {
            try CacheStorage.validateOpenedDirectory(fd, at: root, configuration: settings,
                protectionReader: { _, _ in
                    CacheVolumeProtection(internalVolume: false, encryptedVolume: false)
                })
        }
    }

    @Test func externalPayloadKeepsTheExistingInternalWriteLedger() throws {
        let internalRoot = try fixture()
        defer { try? FileManager.default.removeItem(at: internalRoot) }
        let root = try CacheStorage.writeBudgetRoot(payloadRoot: URL(fileURLWithPath: "/Volumes/Absent/cache"),
                                                    isolated: false, defaultRoot: internalRoot)
        #expect(root == internalRoot)
        let first = try SSDWriteBudget(root: root)
        #expect(first.admit(bytes: 60, capBytesPerDay: 100, now: 0, consume: true))
        let newDisk = try CacheStorage.writeBudgetRoot(payloadRoot: URL(fileURLWithPath: "/Volumes/Other/cache"),
                                                       isolated: false, defaultRoot: internalRoot)
        #expect(!((try SSDWriteBudget(root: newDisk)).admit(bytes: 50, capBytesPerDay: 100,
                                                          now: 0, consume: true)))
    }

    @Test func unlimitedWritesDoNotCreateALedgerDirectory() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let absentRoot = root.appendingPathComponent("unused-ledger")
        let budget = try CacheStorage.makeWriteBudget(
            maxWriteBytesPerDay: 0, payloadRoot: absentRoot, isolated: true)
        #expect(budget == nil)
        #expect(!FileManager.default.fileExists(atPath: absentRoot.path))
    }

    @Test func missingMountCannotCreateFallbackDirectories() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingMount = root.appendingPathComponent("disconnected")
        let selected = missingMount.appendingPathComponent("private-cache")
        let settings = CacheSettings(directory: selected.path, volumeUUID: UUID().uuidString)
        #expect(throws: (any Error).self) {
            try SSDNoFollowIO.prepareDirectory(selected.appendingPathComponent("darkbloom/kv3"),
                                               configuration: settings)
        }
        #expect(!FileManager.default.fileExists(atPath: missingMount.path))
    }

    @Test func replacementMountCannotReceiveCreatedCacheDirectories() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("darkbloom/kv3")
        // The path exists on this real volume, but configuration pins another.
        let settings = CacheSettings(directory: root.path, volumeUUID: UUID().uuidString)
        #expect(throws: (any Error).self) {
            try SSDNoFollowIO.prepareDirectory(cache, configuration: settings)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("darkbloom").path))
    }
}
