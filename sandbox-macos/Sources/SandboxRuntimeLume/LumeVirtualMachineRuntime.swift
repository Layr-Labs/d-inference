import Foundation
import SandboxCore
import SandboxRuntime

public struct LumeRuntimeConfiguration: Sendable {
    public static let pinnedRepository = "https://github.com/trycua/cua.git"
    public static let pinnedCommit = "737dc2a069528abadee67526d138a907e1c52061"
    public static let pinnedSourcePath = "libs/lume"
    public static let pinnedVersion = "0.5.3"

    public let executable: URL
    public let storageDirectory: URL
    public let commandTimeoutSeconds: UInt32
    public let createTimeoutSeconds: UInt32

    public init(
        executable: URL,
        storageDirectory: URL,
        commandTimeoutSeconds: UInt32 = 60,
        createTimeoutSeconds: UInt32 = 7_200
    ) throws {
        guard executable.isFileURL,
              executable.baseURL == nil,
              storageDirectory.isFileURL,
              storageDirectory.baseURL == nil,
              storageDirectory.path.hasPrefix("/"),
              commandTimeoutSeconds > 0,
              createTimeoutSeconds >= commandTimeoutSeconds
        else {
            throw SandboxRuntimeError.unsupported(
                "Lume configuration requires absolute paths and positive timeouts"
            )
        }
        self.executable = executable
            .standardizedFileURL
            .resolvingSymlinksInPath()
        self.storageDirectory = storageDirectory.standardizedFileURL
        self.commandTimeoutSeconds = commandTimeoutSeconds
        self.createTimeoutSeconds = createTimeoutSeconds
    }
}

public actor LumeVirtualMachineRuntime:
    SandboxVirtualMachineRuntime,
    SandboxGuestCommandRuntime
{
    private let configuration: LumeRuntimeConfiguration
    private let processRunner: SandboxProcessRunner
    private var validatedRuntime: ValidatedLumeRuntime?
    private var activeOperations: [String: String] = [:]

    public init(
        configuration: LumeRuntimeConfiguration,
        processRunner: SandboxProcessRunner = SandboxProcessRunner()
    ) {
        self.configuration = configuration
        self.processRunner = processRunner
    }

    public func capabilities() async throws -> SandboxRuntimeCapabilities {
        let version = try await validateRuntime()
        return SandboxRuntimeCapabilities(
            runtime: "lume",
            version: version,
            supportsMacOS: true,
            supportsPause: false,
            supportsSnapshots: false
        )
    }

    public func list() async throws -> [SandboxVirtualMachineRecord] {
        _ = try await validateRuntime()
        let details: [LumeVMDetails] = try await runJSON(
            arguments: storageArguments(["ls", "--format", "json"]),
            timeoutSeconds: configuration.commandTimeoutSeconds,
            operation: "list"
        )
        return details.map(Self.makeRecord)
    }

    public func inspect(name: String) async throws -> SandboxVirtualMachineRecord? {
        guard SandboxVirtualMachineNamePolicy.isValid(name) else {
            throw SandboxRuntimeError.invalidName
        }
        return try await list().first { $0.name == name }
    }

    public func create(
        _ specification: SandboxVirtualMachineSpecification
    ) async throws {
        try beginOperation("create", name: specification.name)
        defer { endOperation(name: specification.name) }

        _ = try await validateRuntime()
        try ensureStorageDirectory()
        if let existing = try await inspect(name: specification.name) {
            guard Self.matches(existing, specification: specification) else {
                throw SandboxRuntimeError.unsupported(
                    "VM \(specification.name) already exists with different resources"
                )
            }
            return
        }

        let arguments: [String]
        switch specification.imageSource {
        case .restoreImage(let url, let unattendedPreset):
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw SandboxRuntimeError.invalidImageReference
            }
            arguments = storageArguments([
                "create",
                specification.name,
                "--os", "macOS",
                "--cpu", String(specification.resources.cpuCount),
                "--memory", "\(specification.resources.memoryBytes)B",
                "--disk-size", "\(specification.diskBytes)B",
                "--ipsw", url.path,
                "--unattended", unattendedPreset,
                "--no-display",
                "--vnc-port", "0",
                "--network", "nat",
            ])
        case .localTemplate(let template):
            guard try await inspect(name: template) != nil else {
                throw SandboxRuntimeError.invalidImageReference
            }
            arguments = [
                "clone",
                template,
                specification.name,
                "--source-storage", configuration.storageDirectory.path,
                "--dest-storage", configuration.storageDirectory.path,
            ]
        }

        do {
            _ = try await run(
                arguments: arguments,
                timeoutSeconds: configuration.createTimeoutSeconds,
                operation: "create"
            )
            guard let created = try await inspect(name: specification.name),
                  created.state == .stopped,
                  Self.matches(created, specification: specification)
            else {
                throw SandboxRuntimeError.malformedOutput(
                    "Lume create completed without the requested stopped VM"
                )
            }
        } catch {
            do {
                try await cleanupFailedCreationIgnoringCancellation(
                    name: specification.name
                )
            } catch let cleanupError {
                throw SandboxRuntimeError.cleanupFailed(
                    operation: "create \(specification.name)",
                    primary: String(describing: error),
                    cleanup: String(describing: cleanupError)
                )
            }
            throw error
        }
    }

    public func start(name: String) async throws {
        guard SandboxVirtualMachineNamePolicy.isValid(name) else {
            throw SandboxRuntimeError.invalidName
        }
        try beginOperation("start", name: name)
        defer { endOperation(name: name) }

        guard let existing = try await inspect(name: name) else {
            throw SandboxRuntimeError.unsupported(
                "cannot start missing VM \(name)"
            )
        }
        if existing.state == .running {
            if existing.guestReady != true {
                try await waitForGuestReady(
                    name: name,
                    timeoutSeconds: configuration.commandTimeoutSeconds
                )
            }
            return
        }
        if existing.state == .starting {
            try await waitForState(
                name: name,
                expected: .running,
                timeoutSeconds: configuration.commandTimeoutSeconds
            )
            try await waitForGuestReady(
                name: name,
                timeoutSeconds: configuration.commandTimeoutSeconds
            )
            return
        }
        guard existing.state == .stopped else {
            throw SandboxRuntimeError.unsupported(
                "cannot start VM \(name) while state is \(existing.state.rawValue)"
            )
        }

        do {
            _ = try await run(
                arguments: storageArguments([
                    "run",
                    name,
                    "--detach",
                    "--display", "none",
                    "--vnc", "disabled",
                ]),
                timeoutSeconds: configuration.commandTimeoutSeconds,
                operation: "start"
            )
            try await waitForState(
                name: name,
                expected: .running,
                timeoutSeconds: configuration.commandTimeoutSeconds
            )
            try await waitForGuestReady(
                name: name,
                timeoutSeconds: configuration.commandTimeoutSeconds
            )
        } catch {
            do {
                try await cleanupFailedStartIgnoringCancellation(name: name)
            } catch let cleanupError {
                throw SandboxRuntimeError.cleanupFailed(
                    operation: "start \(name)",
                    primary: String(describing: error),
                    cleanup: String(describing: cleanupError)
                )
            }
            throw error
        }
    }

    public func stop(name: String) async throws {
        guard SandboxVirtualMachineNamePolicy.isValid(name) else {
            throw SandboxRuntimeError.invalidName
        }
        try beginOperation("stop", name: name)
        defer { endOperation(name: name) }
        try await stopWithoutOperationFence(name: name)
    }

    public func delete(name: String) async throws {
        guard SandboxVirtualMachineNamePolicy.isValid(name) else {
            throw SandboxRuntimeError.invalidName
        }
        try beginOperation("delete", name: name)
        defer { endOperation(name: name) }

        guard let existing = try await inspect(name: name) else {
            return
        }
        guard existing.state == .stopped || existing.state == .failed else {
            throw SandboxRuntimeError.unsupported(
                "refusing to delete VM \(name) while state is \(existing.state.rawValue)"
            )
        }
        _ = try await run(
            arguments: storageArguments(["delete", name, "--force"]),
            timeoutSeconds: configuration.commandTimeoutSeconds,
            operation: "delete"
        )
        guard try await inspect(name: name) == nil else {
            throw SandboxRuntimeError.malformedOutput(
                "Lume delete completed but VM still exists"
            )
        }
    }

    public func execute(
        name: String,
        request: SandboxGuestCommandRequest
    ) async throws -> SandboxGuestCommandResult {
        guard SandboxVirtualMachineNamePolicy.isValid(name) else {
            throw SandboxRuntimeError.invalidName
        }
        guard try await inspect(name: name)?.state == .running else {
            throw SandboxRuntimeError.unsupported(
                "guest commands require a running VM"
            )
        }
        let encodedCommand = LumeGuestCommandEncoder.encode(request)
        let result = try await processRunner.run(
            executable: configuration.executable,
            arguments: [
                "ssh",
                name,
                "--storage", configuration.storageDirectory.path,
                "--timeout", String(request.timeoutSeconds),
                encodedCommand,
            ],
            environment: [
                "LUME_TELEMETRY_ENABLED": "false",
                "NO_COLOR": "1",
            ],
            timeoutSeconds: request.timeoutSeconds + 10
        )
        guard !result.standardOutputTruncated,
              !result.standardErrorTruncated
        else {
            throw SandboxRuntimeError.malformedOutput(
                "Lume guest-command output exceeded the capture limit"
            )
        }
        return SandboxGuestCommandResult(
            exitCode: result.exitCode,
            standardOutput: result.standardOutput,
            standardError: result.standardError
        )
    }

    private func validateRuntime() async throws -> String {
        if let validatedRuntime {
            try LumeRuntimeProvenanceValidator.requireUnchanged(
                validatedRuntime,
                configuration: configuration
            )
            return validatedRuntime.version
        }
        let validation = try LumeRuntimeProvenanceValidator.validate(
            configuration: configuration
        )
        let result = try await run(
            arguments: ["--version"],
            timeoutSeconds: configuration.commandTimeoutSeconds,
            operation: "version"
        )
        let version = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard version == validation.version else {
            throw SandboxRuntimeError.unsupported(
                "expected Lume \(validation.version), got \(version)"
            )
        }
        try LumeRuntimeProvenanceValidator.requireUnchanged(
            validation,
            configuration: configuration
        )
        validatedRuntime = validation
        return version
    }

    private func beginOperation(_ operation: String, name: String) throws {
        guard activeOperations[name] == nil else {
            throw SandboxRuntimeError.operationInProgress(
                name: name,
                operation: activeOperations[name]!
            )
        }
        activeOperations[name] = operation
    }

    private func endOperation(name: String) {
        activeOperations.removeValue(forKey: name)
    }

    private func cleanupFailedStartIgnoringCancellation(
        name: String
    ) async throws {
        let cleanup = Task.detached {
            try await self.stopWithoutOperationFence(name: name)
        }
        try await cleanup.value
    }

    private func cleanupFailedCreationIgnoringCancellation(
        name: String
    ) async throws {
        let cleanup = Task.detached {
            try await self.removePartialVirtualMachine(name: name)
        }
        try await cleanup.value
    }

    private func stopWithoutOperationFence(name: String) async throws {
        guard let existing = try await inspect(name: name) else {
            return
        }
        if existing.state == .stopped {
            return
        }
        _ = try await run(
            arguments: storageArguments(["stop", name]),
            timeoutSeconds: configuration.commandTimeoutSeconds,
            operation: "stop"
        )
        try await waitForStoppedOrAbsent(
            name: name,
            timeoutSeconds: configuration.commandTimeoutSeconds
        )
    }

    private func removePartialVirtualMachine(name: String) async throws {
        guard var existing = try await inspect(name: name) else {
            return
        }
        if existing.state != .stopped && existing.state != .failed {
            try await stopWithoutOperationFence(name: name)
            guard let stopped = try await inspect(name: name) else {
                return
            }
            existing = stopped
        }
        guard existing.state == .stopped || existing.state == .failed else {
            throw SandboxRuntimeError.unsupported(
                "partial VM \(name) did not become deletable"
            )
        }
        _ = try await run(
            arguments: storageArguments(["delete", name, "--force"]),
            timeoutSeconds: configuration.commandTimeoutSeconds,
            operation: "delete partial VM"
        )
        guard try await inspect(name: name) == nil else {
            throw SandboxRuntimeError.malformedOutput(
                "Lume cleanup completed but partial VM still exists"
            )
        }
    }

    private func ensureStorageDirectory() throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: configuration.storageDirectory.path,
            isDirectory: &isDirectory
        )
        if exists {
            guard isDirectory.boolValue else {
                throw SandboxRuntimeError.unsupported(
                    "Lume storage path is not a directory"
                )
            }
            return
        }
        try FileManager.default.createDirectory(
            at: configuration.storageDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func storageArguments(_ arguments: [String]) -> [String] {
        arguments + ["--storage", configuration.storageDirectory.path]
    }

    private func run(
        arguments: [String],
        timeoutSeconds: UInt32,
        operation: String
    ) async throws -> SandboxProcessResult {
        let result = try await processRunner.run(
            executable: configuration.executable,
            arguments: arguments,
            environment: [
                "LUME_TELEMETRY_ENABLED": "false",
                "NO_COLOR": "1",
            ],
            timeoutSeconds: timeoutSeconds
        )
        guard result.exitCode == 0 else {
            let standardError = String(
                decoding: result.standardError,
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SandboxRuntimeError.commandFailed(
                command: "lume \(operation)",
                exitCode: result.exitCode,
                stderr: standardError
            )
        }
        guard !result.standardOutputTruncated,
              !result.standardErrorTruncated
        else {
            throw SandboxRuntimeError.malformedOutput(
                "Lume \(operation) output exceeded the capture limit"
            )
        }
        return result
    }

    private func runJSON<T: Decodable>(
        arguments: [String],
        timeoutSeconds: UInt32,
        operation: String
    ) async throws -> T {
        let result = try await run(
            arguments: arguments,
            timeoutSeconds: timeoutSeconds,
            operation: operation
        )
        do {
            return try JSONDecoder().decode(T.self, from: result.standardOutput)
        } catch {
            throw SandboxRuntimeError.malformedOutput(
                "Lume \(operation) returned invalid JSON"
            )
        }
    }

    private func waitForState(
        name: String,
        expected: SandboxVirtualMachineState,
        timeoutSeconds: UInt32
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
        repeat {
            if try await inspect(name: name)?.state == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        } while clock.now < deadline
        throw SandboxRuntimeError.operationTimedOut(
            "\(name) -> \(expected.rawValue)"
        )
    }

    private func waitForStoppedOrAbsent(
        name: String,
        timeoutSeconds: UInt32
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
        repeat {
            let state = try await inspect(name: name)?.state
            if state == nil || state == .stopped {
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        } while clock.now < deadline
        throw SandboxRuntimeError.operationTimedOut(
            "\(name) -> stopped"
        )
    }

    private func waitForGuestReady(
        name: String,
        timeoutSeconds: UInt32
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
        repeat {
            if try await inspect(name: name)?.guestReady == true {
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        } while clock.now < deadline
        throw SandboxRuntimeError.operationTimedOut(
            "\(name) guest readiness"
        )
    }

    private static func makeRecord(_ details: LumeVMDetails) -> SandboxVirtualMachineRecord {
        SandboxVirtualMachineRecord(
            name: details.name,
            state: state(from: details.status),
            cpuCount: UInt16(exactly: details.cpuCount),
            memoryBytes: details.memorySize,
            diskBytes: details.diskSize.total,
            guestReady: details.sshAvailable
        )
    }

    private static func matches(
        _ record: SandboxVirtualMachineRecord,
        specification: SandboxVirtualMachineSpecification
    ) -> Bool {
        record.cpuCount == specification.resources.cpuCount
            && record.memoryBytes == specification.resources.memoryBytes
            && record.diskBytes == specification.diskBytes
    }

    private static func state(from lumeState: String) -> SandboxVirtualMachineState {
        switch lumeState {
        case "stopped":
            .stopped
        case "starting":
            .starting
        case "running":
            .running
        case "stopping":
            .stopping
        case "paused":
            .paused
        case "provisioning", "pulling":
            .installing
        case "failed":
            .failed
        default:
            .unknown
        }
    }

}

private struct LumeVMDetails: Decodable {
    let name: String
    let cpuCount: Int
    let memorySize: UInt64
    let diskSize: LumeDiskSize
    let status: String
    let sshAvailable: Bool?
}

private struct LumeDiskSize: Decodable {
    let total: UInt64
}
