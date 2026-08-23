import Foundation
import SandboxCore
import SandboxRuntime

public actor LumeVirtualMachineRuntime:
    SandboxVirtualMachineRuntime,
    SandboxGuestCommandRuntime
{
    let configuration: LumeRuntimeConfiguration
    let workspace: LumeRuntimeWorkspace
    let processRunner: SandboxProcessRunner
    var validatedRuntime: ValidatedLumeRuntime?
    var activeOperations: [String: String] = [:]
    var runningProcesses: [String: SandboxManagedProcess] = [:]

    public init(
        configuration: LumeRuntimeConfiguration,
        processRunner: SandboxProcessRunner = SandboxProcessRunner()
    ) {
        self.configuration = configuration
        self.workspace = LumeRuntimeWorkspace(
            storageDirectory: configuration.storageDirectory
        )
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
        let debugInvocationID = UUID().uuidString
        // #region agent log
        SandboxAgentDebugLog.write(
            hypothesisId: "E",
            location: "\(#fileID):\(#line)",
            message: "entered Lume list",
            data: [
                "activeOperations": activeOperations,
                "invocationId": debugInvocationID,
                "runningProcessNames": runningProcesses.keys.sorted(),
            ]
        )
        // #endregion
        _ = try await validateRuntime()
        let details: [LumeVMDetails] = try await runJSON(
            arguments: storageArguments(["ls", "--format", "json"]),
            timeoutSeconds: configuration.commandTimeoutSeconds,
            operation: "list",
            debugTraceID: debugInvocationID
        )
        // #region agent log
        SandboxAgentDebugLog.write(
            hypothesisId: "E",
            location: "\(#fileID):\(#line)",
            message: "decoded Lume list",
            data: [
                "invocationId": debugInvocationID,
                "recordCount": details.count,
                "states": details.map { "\($0.name)=\($0.status)" },
            ]
        )
        // #endregion
        return details.map(Self.makeRecord)
    }

    public func inspect(name: String) async throws -> SandboxVirtualMachineRecord? {
        guard SandboxVirtualMachineNamePolicy.isValid(name) else {
            throw SandboxRuntimeError.invalidName
        }
        return try await list().first { $0.name == name }
    }

    public func execute(
        name: String,
        request: SandboxGuestCommandRequest
    ) async throws -> SandboxGuestCommandResult {
        guard SandboxVirtualMachineNamePolicy.isValid(name) else {
            throw SandboxRuntimeError.invalidName
        }
        try LumeVirtualMachineOwnership.requireOwned(
            name: name,
            in: configuration.storageDirectory
        )
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
            environment: workspace.environment,
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

    func validateRuntime() async throws -> String {
        try workspace.prepare()
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

    func ensureStorageDirectory() throws {
        try workspace.prepare()
    }

    func storageArguments(_ arguments: [String]) -> [String] {
        arguments + ["--storage", configuration.storageDirectory.path]
    }

    func run(
        arguments: [String],
        timeoutSeconds: UInt32,
        operation: String,
        environment: [String: String]? = nil,
        debugTraceID: String? = nil
    ) async throws -> SandboxProcessResult {
        let result = try await processRunner.run(
            executable: configuration.executable,
            arguments: arguments,
            environment: environment ?? workspace.environment,
            timeoutSeconds: timeoutSeconds,
            debugTraceID: debugTraceID
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
        operation: String,
        debugTraceID: String
    ) async throws -> T {
        // #region agent log
        SandboxAgentDebugLog.write(
            hypothesisId: "A",
            location: "\(#fileID):\(#line)",
            message: "entered Lume JSON command",
            data: [
                "argumentCount": arguments.count,
                "operation": operation,
                "traceId": debugTraceID,
            ]
        )
        // #endregion
        let result = try await run(
            arguments: arguments,
            timeoutSeconds: timeoutSeconds,
            operation: operation,
            debugTraceID: debugTraceID
        )
        let debugRedactions = [
            configuration.storageDirectory.path,
            FileManager.default.homeDirectoryForCurrentUser.path,
            workspace.supportDirectory.path,
        ]
        // #region agent log
        SandboxAgentDebugLog.write(
            hypothesisId: "A",
            location: "\(#fileID):\(#line)",
            message: "received raw Lume JSON command output",
            data: [
                "operation": operation,
                "stderr": SandboxAgentDebugLog.output(
                    result.standardError,
                    redacting: debugRedactions
                ),
                "stdout": SandboxAgentDebugLog.output(
                    result.standardOutput,
                    redacting: debugRedactions
                ),
                "traceId": debugTraceID,
            ]
        )
        // #endregion
        do {
            return try JSONDecoder().decode(T.self, from: result.standardOutput)
        } catch {
            // #region agent log
            SandboxAgentDebugLog.write(
                hypothesisId: "D",
                location: "\(#fileID):\(#line)",
                message: "failed to decode Lume JSON command output",
                data: [
                    "decodeError": String(reflecting: error),
                    "operation": operation,
                    "traceId": debugTraceID,
                ]
            )
            // #endregion
            throw SandboxRuntimeError.malformedOutput(
                "Lume \(operation) returned invalid JSON"
            )
        }
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
