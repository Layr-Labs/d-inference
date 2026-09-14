import CryptoKit
import Darwin
import Foundation
import SandboxRuntime
@testable import SandboxRuntimeLume

/// Real source locks, capacity receipts and private sparse material files. The
/// native lifecycle is a bounded subprocess fixture, not a running macOS VM.
final class LumeQualificationCleanupFixture: Sendable {
    let base: LumeQualificationFixture
    let capability: LumeQualificationCloneCapability
    var clone: URL { base.vm.storage.appendingPathComponent(base.specification.name) }
    var materialRoot: URL { clone.appendingPathComponent(".darkbloom-guest") }

    init() async throws {
        base = try await LumeQualificationFixture()
        capability = try await base.issue()
        try await base.runtime.createQualificationClone(capability)
    }

    func prepareMaterials(instanceID: UUID? = nil) throws {
        let owner = try LumeVirtualMachineOwnership.requireOwned(name: base.specification.name,
            owner: .init(operationScope: base.lease.scope), in: base.vm.storage)
        let instanceID = instanceID ?? owner.installationID
        try FileManager.default.createDirectory(at: materialRoot, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let control = materialRoot.appendingPathComponent("control.cdr"), workspace = materialRoot.appendingPathComponent("workspace.cdr")
        let controlBytes: UInt64 = 128 * 1_048_576
        for (path, bytes, mode) in [(control, controlBytes, 0o400), (workspace, base.lease.workspaceBytes, 0o600)] {
            guard FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw POSIXError(.EIO) }
            let file = try FileHandle(forWritingTo: path)
            try file.truncate(atOffset: bytes); try file.close()
            guard chmod(path.path, mode_t(mode)) == 0 else { throw POSIXError(.EIO) }
        }
        let manifest: [String: Any] = ["schema_version": 1, "instanceID": instanceID.uuidString,
            "controlPath": control.path, "controlBytes": controlBytes, "workspacePath": workspace.path,
            "workspaceDiskBytes": base.lease.workspaceBytes,
            "images": [["role": "control", "path": control.path, "bytes": controlBytes, "sha256": Self.controlSHA256, "read_only": true],
                       ["role": "workspace", "path": workspace.path, "bytes": base.lease.workspaceBytes, "sha256": String(repeating: "0", count: 64), "read_only": false]]]
        try write(manifest, to: materialRoot.appendingPathComponent("material-manifest.json"))
        // Synthetic fixed fixture credential, never a production credential.
        try write(["version": 1, "instanceID": instanceID.uuidString,
                   "credential": Data(repeating: 73, count: 32).base64EncodedString()], to: materialRoot.appendingPathComponent("broker.json"))
    }

    func setRunning(_ running: Bool) throws {
        try Data((running ? "running\n" : "stopped\n").utf8).write(to: clone.appendingPathComponent("fixture-state"))
    }

    func observe() async throws -> LumeQualificationCloneObservation {
        try await base.runtime.observeQualificationClone(capability)
    }

    func deleteAndRelease() async throws {
        try setRunning(false)
        try await base.runtime.release(scope: base.lease.scope, name: base.specification.name)
    }

    func remove() { base.remove() }

    private static let controlSHA256: String = {
        var hash = SHA256(); let zeros = Data(count: 1_048_576)
        for _ in 0..<128 { hash.update(data: zeros) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }()

    private func write(_ object: [String: Any], to path: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: path)
        guard chmod(path.path, 0o600) == 0 else { throw POSIXError(.EIO) }
    }
}
