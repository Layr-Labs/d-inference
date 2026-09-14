import Darwin
import Foundation
@testable import HostRuntimeCoordination
import XCTest

struct HostRuntimeTestFixture {
    let root: URL
    let directory: URL
    var lock: URL { directory.appendingPathComponent(HostRuntimeAuthority.lockName) }
    var maintenance: URL { directory.appendingPathComponent(HostRuntimeAuthority.maintenanceFileName) }
    var authority: HostRuntimeAuthority {
        HostRuntimeAuthority(testDirectory: directory, ownerUID: geteuid(), groupID: getegid())
    }
    init(createAuthority: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("host-runtime-\(UUID().uuidString)")
        directory = root.appendingPathComponent("authority")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        if createAuthority { try self.createAuthority() }
    }
    func createAuthority() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o750])
        try createLock()
    }
    func createLock() throws {
        let descriptor = open(lock.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o660)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard fchmod(descriptor, 0o660) == 0, fchown(descriptor, geteuid(), getegid()) == 0 else {
            throw POSIXError(.EIO)
        }
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
