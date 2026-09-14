import Foundation
import SandboxRuntime

/// Only the root staging scope supplies the production executor. A dedicated
/// worker retains its machine lease without passing it to vendor tools. Mutating
/// clients are not killed on caller cancellation or an observation deadline.
struct AccountlessMountSystemTools {
    enum Tool: String { case hdiutil = "/usr/bin/hdiutil", diskutil = "/usr/sbin/diskutil", lsof = "/usr/sbin/lsof" }
    typealias Execute = (Tool, [String], UInt32) async throws -> SandboxProcessResult
    private let execute: Execute

    init(operation: AccountlessStagingMaintenance) {
        execute = { tool, arguments, timeout in
            let child = try operation.startOwnedSystemCommand(tool: tool, arguments: arguments)
            return try await AccountlessSystemCommandWait.naturalExit(of: child, seconds: timeout)
        }
    }
    init(execute: @escaping Execute) { self.execute = execute }

    var disks: AccountlessDiskTools {
        .init(execute: { arguments in try await execute(.diskutil, arguments, 30) })
    }

    func inventory() async throws -> AccountlessAttachmentInventory {
        try await .init(checked(.hdiutil, ["info", "-plist"], seconds: 30))
    }

    func requireOnlyRetainedImageOpener(image: URL, pid: Int32, descriptor: Int32) async throws {
        let result = try await execute(.lsof, ["-nP", "-Fpf", "--", image.path], 30)
        try AccountlessImageOpeners.requireOnlyRetainedDescriptor(result, pid: pid, descriptor: descriptor)
    }

    func attach(_ image: URL, writable: Bool) async throws -> [AccountlessAttachmentEntity] {
        let result = try await checked(.hdiutil, ["attach", writable ? "-readwrite" : "-readonly", "-nomount",
            "-nobrowse", "-noautoopen", "-owners", "on", "-plist", image.path], seconds: 120)
        return try AccountlessAttachmentInventory.entities(AccountlessDiskPlist.root(result)["system-entities"])
    }

    func mount(_ binding: AccountlessAPFSVolumeBinding, at mountpoint: URL, writable: Bool) async throws {
        _ = try await checked(.diskutil, ["mount"] + (writable ? [] : ["readOnly"]) + ["nobrowse", "-mountOptions",
            "owners,nosuid,nodev,noexec", "-mountPoint", mountpoint.path, binding.dataVolume.nodePath], seconds: 120)
    }

    func detach(_ wholeDisk: AccountlessDiskIdentifier) async throws {
        guard wholeDisk.isWholeDisk else { throw AccountlessDiskError.invalidInventory }
        _ = try await checked(.hdiutil, ["detach", wholeDisk.nodePath], seconds: 120)
    }

    /// Info may omit a content hint after interrupted attach output. Probe only
    /// whole devices belonging to the exact image; never infer the next disk ID.
    func wholeDisk(of image: AccountlessAttachedImage, excluding: Set<AccountlessDiskIdentifier>) async throws -> AccountlessDiskIdentifier {
        guard image.devices.isDisjoint(with: excluding) else { throw AccountlessDiskError.bindingChanged }
        let candidates = image.entities.map(\.device).filter(\.isWholeDisk)
        guard !candidates.isEmpty, candidates.count <= 8 else { throw AccountlessDiskError.invalidInventory }
        var matches: [AccountlessDiskIdentifier] = []
        for candidate in candidates {
            let info = try await checked(.diskutil, ["list", "-plist", candidate.nodePath], seconds: 30)
            let disks = try AccountlessDiskPlist.records(AccountlessDiskPlist.root(info)["AllDisksAndPartitions"])
            guard disks.count == 1, try AccountlessDiskPlist.disk(disks[0]["DeviceIdentifier"]) == candidate else {
                throw AccountlessDiskError.bindingChanged
            }
            if disks[0]["Content"] as? String == "GUID_partition_scheme" { matches.append(candidate) }
        }
        guard matches.count == 1 else { throw AccountlessDiskError.invalidInventory }
        return matches[0]
    }

    private func checked(_ tool: Tool, _ arguments: [String], seconds: UInt32) async throws -> Data {
        let result = try await execute(tool, arguments, seconds)
        guard result.exitCode == 0, !result.standardOutputTruncated, !result.standardErrorTruncated else {
            throw AccountlessDiskError.commandFailed
        }
        return result.standardOutput
    }
}
