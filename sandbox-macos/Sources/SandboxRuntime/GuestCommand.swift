import Foundation

public struct SandboxGuestCommandRequest: Equatable, Sendable {
    public static let maximumArgumentCount = 256
    public static let maximumEnvironmentVariableCount = 128
    public static let maximumPathBytes = 4_096
    public static let maximumValueBytes = 16_384
    public static let maximumEnvironmentKeyBytes = 128
    public static let maximumAggregateInputBytes = 65_536

    public let idempotencyKey: UUID
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: String
    public let timeoutSeconds: UInt32

    public init(
        idempotencyKey: UUID,
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String = "/Users/lume",
        timeoutSeconds: UInt32 = 900
    ) throws {
        let aggregateInputBytes = executable.utf8.count
            + workingDirectory.utf8.count
            + arguments.reduce(0) { $0 + $1.utf8.count }
            + environment.reduce(0) {
                $0 + $1.key.utf8.count + $1.value.utf8.count
            }
        guard executable.hasPrefix("/"),
              !executable.contains("\0"),
              executable.utf8.count <= Self.maximumPathBytes,
              workingDirectory.hasPrefix("/"),
              !workingDirectory.contains("\0"),
              workingDirectory.utf8.count <= Self.maximumPathBytes,
              (1...900).contains(timeoutSeconds),
              arguments.count <= Self.maximumArgumentCount,
              arguments.allSatisfy({
                  !$0.contains("\0")
                      && $0.utf8.count <= Self.maximumValueBytes
              }),
              environment.count <= Self.maximumEnvironmentVariableCount,
              environment.allSatisfy({ key, value in
                  Self.validEnvironmentKey(key)
                      && !Self.isReservedEnvironmentKey(key)
                      && key.utf8.count
                          <= Self.maximumEnvironmentKeyBytes
                      && !value.contains("\0")
                      && value.utf8.count <= Self.maximumValueBytes
              }),
              aggregateInputBytes <= Self.maximumAggregateInputBytes
        else {
            throw SandboxRuntimeError.unsupported(
                "guest command contains an invalid path, environment, size, NUL, or timeout"
            )
        }
        self.idempotencyKey = idempotencyKey
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeoutSeconds = timeoutSeconds
    }

    private static func validEnvironmentKey(_ key: String) -> Bool {
        let scalars = key.unicodeScalars
        guard let first = scalars.first,
              first.value == 0x5F
                  || (0x41...0x5A).contains(first.value)
                  || (0x61...0x7A).contains(first.value)
        else {
            return false
        }
        return scalars.dropFirst().allSatisfy {
            $0.value == 0x5F
                || (0x41...0x5A).contains($0.value)
                || (0x61...0x7A).contains($0.value)
                || (0x30...0x39).contains($0.value)
        }
    }

    private static func isReservedEnvironmentKey(_ key: String) -> Bool {
        switch key {
        case "BASH_ENV", "ENV", "HOME", "LANG", "LC_ALL", "PATH",
             "TMPDIR", "ZDOTDIR":
            return true
        default:
            return key.hasPrefix("DARKBLOOM_") || key.hasPrefix("DYLD_")
        }
    }
}

public struct SandboxGuestCommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: Data
    public let standardOutputTruncated: Bool
    public let standardErrorTruncated: Bool
    public let timedOut: Bool

    public init(
        exitCode: Int32,
        standardOutput: Data,
        standardError: Data,
        standardOutputTruncated: Bool = false,
        standardErrorTruncated: Bool = false,
        timedOut: Bool = false
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.standardOutputTruncated = standardOutputTruncated
        self.standardErrorTruncated = standardErrorTruncated
        self.timedOut = timedOut
    }
}

public protocol SandboxGuestCommandRuntime: Sendable {
    func execute(
        name: String,
        request: SandboxGuestCommandRequest
    ) async throws -> SandboxGuestCommandResult
}
