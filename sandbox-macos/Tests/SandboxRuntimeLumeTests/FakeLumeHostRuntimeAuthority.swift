import Darwin
import Foundation
@testable import HostRuntimeCoordination

extension FakeLumeFixture {
    /// Uses the host-runtime package's existing internal fixture initializer;
    /// production authority validation and real kernel locking stay enabled.
    func makeTestHostRuntimeAuthority() throws -> HostRuntimeAuthority {
        let directory = self.directory.resolvingSymlinksInPath().appendingPathComponent("authority")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o750])
        let path = directory.appendingPathComponent(HostRuntimeAuthority.lockName)
        try Data().write(to: path)
        guard chmod(path.path, 0o660) == 0 else { throw POSIXError(.EACCES) }
        return HostRuntimeAuthority(testDirectory: directory, ownerUID: geteuid(), groupID: getegid())
    }
}
