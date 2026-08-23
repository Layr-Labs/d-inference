import Foundation
import SandboxRuntime

public struct MacOSBaseImagePreparationReport: Codable, Equatable, Sendable {
    public let name: String
    public let runtimeVersion: String
    public let guestOperatingSystemVersion: String
    public let guestArchitecture: String
    public let cpuCount: UInt16
    public let memoryBytes: UInt64
    public let diskBytes: UInt64

    public init(
        name: String,
        runtimeVersion: String,
        guestOperatingSystemVersion: String,
        guestArchitecture: String,
        cpuCount: UInt16,
        memoryBytes: UInt64,
        diskBytes: UInt64
    ) {
        self.name = name
        self.runtimeVersion = runtimeVersion
        self.guestOperatingSystemVersion = guestOperatingSystemVersion
        self.guestArchitecture = guestArchitecture
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
    }
}

public enum MacOSBaseImagePreparationError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    case guestCommand(executable: String, exitCode: Int32, stderr: String)
    case invalidGuestFact(String)
    case cleanup(primary: String, cleanup: String)

    public var description: String {
        switch self {
        case .guestCommand(let executable, let exitCode, let stderr):
            return "guest command \(executable) exited \(exitCode): \(stderr)"
        case .invalidGuestFact(let fact):
            return "base image returned invalid guest fact: \(fact)"
        case .cleanup(let primary, let cleanup):
            return "base preparation failed (\(primary)); cleanup stop also failed (\(cleanup))"
        }
    }
}

public struct MacOSBaseImagePreparer: Sendable {
    private let runtime: LumeVirtualMachineRuntime

    public init(runtime: LumeVirtualMachineRuntime) {
        self.runtime = runtime
    }

    public func prepare(
        specification: SandboxVirtualMachineSpecification
    ) async throws -> MacOSBaseImagePreparationReport {
        let capabilities = try await runtime.capabilities()
        try await runtime.create(specification)
        try await runtime.start(name: specification.name)

        do {
            let operatingSystemVersion = try await guestFact(
                name: specification.name,
                executable: "/usr/bin/sw_vers",
                arguments: ["-productVersion"]
            )
            let architecture = try await guestFact(
                name: specification.name,
                executable: "/usr/bin/uname",
                arguments: ["-m"]
            )
            guard architecture == "arm64" else {
                throw MacOSBaseImagePreparationError.invalidGuestFact(
                    "architecture \(architecture)"
                )
            }
            try await runtime.stop(name: specification.name)
            guard let record = try await runtime.inspect(name: specification.name),
                  record.state == .stopped,
                  let cpuCount = record.cpuCount,
                  let memoryBytes = record.memoryBytes,
                  let diskBytes = record.diskBytes
            else {
                throw SandboxRuntimeError.malformedOutput(
                    "prepared base VM did not settle in stopped state"
                )
            }
            return MacOSBaseImagePreparationReport(
                name: record.name,
                runtimeVersion: capabilities.version,
                guestOperatingSystemVersion: operatingSystemVersion,
                guestArchitecture: architecture,
                cpuCount: cpuCount,
                memoryBytes: memoryBytes,
                diskBytes: diskBytes
            )
        } catch {
            do {
                try await runtime.stop(name: specification.name)
            } catch let cleanupError {
                throw MacOSBaseImagePreparationError.cleanup(
                    primary: String(describing: error),
                    cleanup: String(describing: cleanupError)
                )
            }
            throw error
        }
    }

    private func guestFact(
        name: String,
        executable: String,
        arguments: [String]
    ) async throws -> String {
        let result = try await runtime.execute(
            name: name,
            request: SandboxGuestCommandRequest(
                idempotencyKey: UUID(),
                executable: executable,
                arguments: arguments,
                timeoutSeconds: 30
            )
        )
        guard result.exitCode == 0 else {
            throw MacOSBaseImagePreparationError.guestCommand(
                executable: executable,
                exitCode: result.exitCode,
                stderr: String(decoding: result.standardError, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let value = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 128,
              !value.contains("\0")
        else {
            throw MacOSBaseImagePreparationError.invalidGuestFact(executable)
        }
        return value
    }
}
