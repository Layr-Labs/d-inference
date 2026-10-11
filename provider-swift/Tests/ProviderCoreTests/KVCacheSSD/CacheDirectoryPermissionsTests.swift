import Darwin
import Foundation
import Testing
@testable import ProviderCore

@Suite("Cache directory ACL boundary")
struct CacheDirectoryPermissionsTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("cache-acl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return root
    }

    private func addACL(_ text: String, to directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", text, directory.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func privateDirectoryWithoutAnExtendedACLIsAccepted() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let clear = Process()
        clear.executableURL = URL(fileURLWithPath: "/bin/chmod")
        clear.arguments = ["-N", root.path]
        try clear.run()
        clear.waitUntilExit()
        #expect(clear.terminationStatus == 0)
        _ = try CacheVolume.inspect(directory: root.path)
    }

    @Test func writeGrantIsRejectedDespitePrivateModeBits() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try addACL("everyone allow write,append,delete_child", to: root)
        var info = stat()
        #expect(stat(root.path, &info) == 0)
        #expect(info.st_mode & 0o077 == 0)
        #expect(throws: (any Error).self) { try CacheVolume.inspect(directory: root.path) }
    }

    @Test func writeGrantAddedAfterSelectionStopsActiveIO() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = try CacheVolume.inspect(directory: root.path)
        let fd = try SSDNoFollowIO.openDirectoryChain(root)
        defer { close(fd) }
        let settings = CacheSettings(directory: selected.directory, volumeUUID: selected.uuid)
        try CacheStorage.validateOpenedDirectory(fd, at: root, configuration: settings)
        try addACL("everyone allow writeattr,writeextattr,writesecurity", to: root)
        #expect(throws: (any Error).self) {
            try CacheStorage.validateOpenedDirectory(fd, at: root, configuration: settings)
        }
    }

    @Test func inheritedWriteGrantIsRejectedDespitePrivateModeBits() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try addACL("everyone allow write,append,file_inherit,directory_inherit", to: root)
        let child = root.appendingPathComponent("inherited")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        var info = stat()
        #expect(stat(child.path, &info) == 0)
        #expect(info.st_mode & 0o077 == 0)
        #expect(throws: (any Error).self) { try CacheVolume.inspect(directory: child.path) }
    }

    @Test func descendantWriteGrantStopsDirectoryCreation() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = try CacheVolume.inspect(directory: root.path)
        let child = root.appendingPathComponent("darkbloom")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        try addACL("everyone allow write,append", to: child)
        let settings = CacheSettings(directory: selected.directory, volumeUUID: selected.uuid)
        #expect(throws: (any Error).self) {
            try SSDNoFollowIO.prepareDirectory(child.appendingPathComponent("kv3"), configuration: settings)
        }
        #expect(!FileManager.default.fileExists(atPath: child.appendingPathComponent("kv3").path))
    }

    @Test func readAndDenyACLsRemainSupported() throws {
        let root = try fixture()
        defer {
            let clear = Process()
            clear.executableURL = URL(fileURLWithPath: "/bin/chmod")
            clear.arguments = ["-N", root.path]
            try? clear.run()
            clear.waitUntilExit()
            try? FileManager.default.removeItem(at: root)
        }
        try addACL("everyone allow readattr,readextattr,readsecurity", to: root)
        try addACL("everyone deny delete", to: root)
        _ = try CacheVolume.inspect(directory: root.path)
    }
}
