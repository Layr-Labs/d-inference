import Darwin
import Foundation
import SandboxCore
import SandboxRuntime

/// Root verifies the production runtime, then runs its read-only status command
/// as the selected source owner. This performs no Virtualization.framework boot
/// and must run BEFORE root takes the source's config/POSIX owner locks.
package struct LumeRootNativeInspector {
    private let configuration: LumeRuntimeConfiguration
    private let ownerUID: uid_t
    private let ownerGID: gid_t
    private let runtime: ValidatedLumeRuntime

    package init(configuration: LumeRuntimeConfiguration, ownerUID: uid_t, ownerGID: gid_t) throws {
        guard getuid() == 0, geteuid() == 0, getegid() == 0, ownerUID > 0, ownerUID != .max,
              ownerGID > 0, ownerGID != .max, case .production = configuration.trustPolicy else {
            throw SandboxRuntimeError.unsupported("native base inspection requires root and the production runtime")
        }
        self.configuration = configuration; self.ownerUID = ownerUID; self.ownerGID = ownerGID
        runtime = try LumeRuntimeProvenanceValidator.validate(configuration: configuration)
    }

    package func requireStopped(name: String, resources: SandboxResourceSpecification,
                                diskBytes: UInt64, runner: SandboxProcessRunner = .init()) async throws {
        guard SandboxVirtualMachineNamePolicy.isValid(name), getuid() == 0, geteuid() == 0, getegid() == 0 else {
            throw SandboxRuntimeError.invalidName
        }
        let storage = try LumePrivilegedSourceDirectory(path: configuration.storageDirectory, ownerUID: ownerUID, ownerGID: ownerGID)
        let source = try storage.child(name)
        // Native get can clean a completed provisioning marker. Refuse it
        // before invocation so this inspection cannot repair source authority.
        for marker in [".provisioning", "resize.lock.json", "disk.img.pre-resize", "config.json.pre-resize"] {
            try source.requireAbsent(marker)
        }
        let workspace = LumeRuntimeWorkspace(storageDirectory: configuration.storageDirectory)
        _ = try storage.child(LumeRuntimeWorkspace.supportDirectoryName)
        var environment = workspace.environment
        environment["HOME"] = workspace.supportDirectory.path
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["LANG"] = "C"
        let prefix = ["-n", "-u", "#\(ownerUID)", "-g", "#\(ownerGID)", "--", "/usr/bin/env", "-i"]
            + environment.keys.sorted().map { $0 + "=" + environment[$0]! } + [configuration.executable.path]
        try LumeRuntimeProvenanceValidator.requireUnchanged(runtime, configuration: configuration)
        let version = try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/sudo"),
            arguments: prefix + ["--version"], timeoutSeconds: 30, maximumOutputBytes: 4096)
        guard version.exitCode == 0, !version.standardOutputTruncated, !version.standardErrorTruncated,
              String(decoding: version.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == runtime.version else {
            throw SandboxRuntimeError.unsupported("native base runtime version could not be verified")
        }
        let result = try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/sudo"),
            arguments: prefix + ["get", name, "--format", "json", "--storage", configuration.storageDirectory.path],
            timeoutSeconds: 30, maximumOutputBytes: 64 * 1024)
        guard result.exitCode == 0, !result.standardOutputTruncated, !result.standardErrorTruncated else {
            throw SandboxRuntimeError.unsupported("native base stopped-state inspection failed")
        }
        try Self.requireStopped(result.standardOutput, name: name, resources: resources, diskBytes: diskBytes)
        try source.validate(); try storage.validate()
        try LumeRuntimeProvenanceValidator.requireUnchanged(runtime, configuration: configuration)
    }

    package func requireSourceNamespace(storage: URL, ownerUID: uid_t, ownerGID: gid_t) throws {
        guard configuration.storageDirectory.standardizedFileURL == storage.standardizedFileURL,
              self.ownerUID == ownerUID, self.ownerGID == ownerGID else {
            throw SandboxRuntimeError.unsupported("native inspection refers to a different source owner or namespace")
        }
    }

    static func requireStopped(_ data: Data, name: String, resources: SandboxResourceSpecification, diskBytes: UInt64) throws {
        guard data.count <= 64 * 1024 else { throw SandboxRuntimeError.unsupported("native status is oversized") }
        try SandboxJSONIntegrity.requireNoDuplicateKeys(data)
        let records = try JSONDecoder().decode([Details].self, from: data)
        guard records.count == 1, records[0].name == name, records[0].os.lowercased() == "macos",
              records[0].status == "stopped", records[0].provisioningOperation == nil,
              records[0].cpuCount == resources.cpuCount, records[0].memorySize == resources.memoryBytes,
              records[0].diskSize.total == diskBytes else {
            throw SandboxRuntimeError.unsupported("native source is not provably stopped with the reserved resources")
        }
    }

    private struct Details: Decodable {
        let name: String; let os: String; let status: String; let provisioningOperation: String?
        let cpuCount: UInt16; let memorySize: UInt64; let diskSize: Disk
    }
    private struct Disk: Decodable { let total: UInt64 }
}
