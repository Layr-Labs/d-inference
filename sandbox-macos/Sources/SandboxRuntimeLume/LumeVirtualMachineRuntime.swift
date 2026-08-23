import Foundation
import SandboxCore
import SandboxRuntime

public struct LumeRuntimeConfiguration: Sendable {
    public static let pinnedCommit = "737dc2a069528abadee67526d138a907e1c52061"
    public static let pinnedVersion = "0.5.3"

    public let executable: URL
    public let storageDirectory: URL
    public let expectedVersion: String
    public let commandTimeoutSeconds: UInt32
    public let createTimeoutSeconds: UInt32

    public init(
        executable: URL,
        storageDirectory: URL,
        expectedVersion: String = pinnedVersion,
        commandTimeoutSeconds: UInt32 = 60,
        createTimeoutSeconds: UInt32 = 7_200
    ) throws {
        guard executable.isFileURL,
              executable.baseURL == nil,
              storageDirectory.isFileURL,
              storageDirectory.baseURL == nil,
              storageDirectory.path.hasPrefix("/"),
              !expectedVersion.isEmpty,
              commandTimeoutSeconds > 0,
              createTimeoutSeconds >= commandTimeoutSeconds
        else {
            throw SandboxRuntimeError.unsupported(
                "Lume configuration requires absolute paths and positive timeouts"
            )
        }
        self.executable = executable.standardizedFileURL
        self.storageDirectory = storageDirectory.standardizedFileURL
        self.expectedVersion = expectedVersion
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
    private var validatedVersion: String?

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
        guard Self.validName(name) else {
            throw SandboxRuntimeError.invalidName
        }
        return try await list().first { $0.name == name }
    }

    public func create(
        _ specification: SandboxVirtualMachineSpecification
    ) async throws {
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
    }

    public func start(name: String) async throws {
        guard Self.validName(name) else {
            throw SandboxRuntimeError.invalidName
        }
        if let existing = try await inspect(name: name), existing.state == .running {
            if existing.guestReady != true {
                try await waitForGuestReady(
                    name: name,
                    timeoutSeconds: configuration.commandTimeoutSeconds
                )
            }
            return
        }
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
    }

    public func stop(name: String, force: Bool) async throws {
        guard Self.validName(name) else {
            throw SandboxRuntimeError.invalidName
        }
        guard let existing = try await inspect(name: name) else {
            return
        }
        if existing.state == .stopped {
            return
        }
        _ = force
        _ = try await run(
            arguments: storageArguments(["stop", name]),
            timeoutSeconds: configuration.commandTimeoutSeconds,
            operation: "stop"
        )
        try await waitForState(
            name: name,
            expected: .stopped,
            timeoutSeconds: configuration.commandTimeoutSeconds
        )
    }

    public func delete(name: String) async throws {
        guard Self.validName(name) else {
            throw SandboxRuntimeError.invalidName
        }
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
        guard Self.validName(name) else {
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
        if let validatedVersion {
            return validatedVersion
        }
        let result = try await run(
            arguments: ["--version"],
            timeoutSeconds: configuration.commandTimeoutSeconds,
            operation: "version"
        )
        let version = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard version == configuration.expectedVersion else {
            throw SandboxRuntimeError.unsupported(
                "expected Lume \(configuration.expectedVersion), got \(version)"
            )
        }
        validatedVersion = version
        return version
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

    private static func validName(_ name: String) -> Bool {
        guard (1...63).contains(name.utf8.count),
              (name.first?.isLetter == true || name.first?.isNumber == true),
              (name.last?.isLetter == true || name.last?.isNumber == true)
        else {
            return false
        }
        return name.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-"
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
