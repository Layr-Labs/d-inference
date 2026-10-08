import Foundation
import Darwin
import DarkbloomClusterProcess

/// The local equivalent of the fixed installed SSH owner command. No caller
/// arguments, environment, script or shell expression crosses this API.
public struct ClusterLocalOwnerConfiguration: Sendable {
    public let installedDarkbloom: URL

    public init(installedDarkbloom: URL) throws {
        let path = installedDarkbloom.path
        guard installedDarkbloom.isFileURL, path.hasPrefix("/"), path.utf8.count <= 1024,
              path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.utf8.contains(where: { $0 < 32 || $0 == 127 }) else {
            throw ClusterOwnerStateError.invalid("Invalid installed local owner path")
        }
        self.installedDarkbloom = installedDarkbloom
    }

    func launch() throws -> ClusterWorkerLaunch {
        var information = stat()
        guard lstat(installedDarkbloom.path, &information) == 0, information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid(), information.st_nlink == 1,
              information.st_mode & 0o022 == 0, information.st_mode & 0o111 != 0 else {
            throw ClusterOwnerStateError.invalid("Installed local owner is unsafe or not executable")
        }
        return .init(executable: installedDarkbloom, arguments: ["cluster", "worker-owner", "--stdio"],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"])
    }
}
