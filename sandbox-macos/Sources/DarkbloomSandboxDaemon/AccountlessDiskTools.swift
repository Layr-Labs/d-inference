import Foundation
import SandboxRuntime

/// Bounded system reads for an already-authorized image attachment. The whole
/// disk must come from that image's hdiutil inventory; this client never grants
/// image authority and never accepts a user-supplied mount or device path.
struct AccountlessDiskTools {
    typealias Execute = ([String]) async throws -> SandboxProcessResult
    private let execute: Execute

    init(runner: SandboxProcessRunner = .init()) {
        execute = { arguments in
            try await runner.run(executable: URL(fileURLWithPath: "/usr/sbin/diskutil"),
                arguments: arguments, timeoutSeconds: 30, maximumOutputBytes: 4 * 1_048_576)
        }
    }

    init(execute: @escaping Execute) { self.execute = execute }

    /// Use within operation.withOfflineImage so its child retains the existing
    /// machine lease. The ordinary runner initializer remains read-only.
    init(operation: AccountlessStagingMaintenance) {
        execute = { arguments in
            let child = try operation.startOwnedProcess(executable: URL(fileURLWithPath: "/usr/sbin/diskutil"),
                arguments: arguments)
            return try await child.wait(timeoutSeconds: 30, cooperativeGracePeriod: .zero)
        }
    }

    func selectDataVolume(for wholeDisk: AccountlessDiskIdentifier) async throws -> AccountlessAPFSVolumeBinding {
        guard wholeDisk.isWholeDisk else { throw AccountlessDiskError.invalidInventory }
        let listing = try await read(["list", "-plist", wholeDisk.nodePath])
        let physical = try AccountlessAPFSVolumeBinding.physicalStore(in: listing, wholeDisk: wholeDisk)
        let info = try await read(["info", "-plist", physical.nodePath])
        let container = try AccountlessAPFSVolumeBinding.container(in: info, physicalStore: physical)
        let volumes = try await read(["apfs", "list", "-plist", container.rawValue])
        return try AccountlessAPFSVolumeBinding.select(in: volumes, wholeDisk: wholeDisk,
            physicalStore: physical, container: container)
    }

    func requireMounted(_ binding: AccountlessAPFSVolumeBinding, at mountpoint: URL, writable: Bool) async throws {
        let info = try await read(["info", "-plist", binding.dataVolume.nodePath])
        try binding.requireMounted(info, at: mountpoint, writable: writable)
    }

    private func read(_ arguments: [String]) async throws -> Data {
        try Task.checkCancellation()
        let result = try await execute(arguments)
        guard result.exitCode == 0, !result.standardOutputTruncated, !result.standardErrorTruncated else {
            throw AccountlessDiskError.commandFailed
        }
        try Task.checkCancellation()
        _ = try AccountlessDiskPlist.root(result.standardOutput)
        return result.standardOutput
    }
}
