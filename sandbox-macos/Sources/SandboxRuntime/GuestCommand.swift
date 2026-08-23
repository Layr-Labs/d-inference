import Foundation

public struct SandboxGuestCommandRequest: Equatable, Sendable {
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
        guard executable.hasPrefix("/"),
              !executable.contains("\0"),
              workingDirectory.hasPrefix("/"),
              !workingDirectory.contains("\0"),
              (1...900).contains(timeoutSeconds),
              arguments.allSatisfy({ !$0.contains("\0") }),
              environment.allSatisfy({ key, value in
                  Self.validEnvironmentKey(key) && !value.contains("\0")
              })
        else {
            throw SandboxRuntimeError.unsupported(
                "guest command contains an invalid path, environment, NUL, or timeout"
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
        guard let first = key.first,
              first == "_" || first.isLetter
        else {
            return false
        }
        return key.dropFirst().allSatisfy {
            $0 == "_" || $0.isLetter || $0.isNumber
        }
    }
}

public struct SandboxGuestCommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: Data
    public let standardOutputTruncated: Bool
    public let standardErrorTruncated: Bool

    public init(
        exitCode: Int32,
        standardOutput: Data,
        standardError: Data,
        standardOutputTruncated: Bool = false,
        standardErrorTruncated: Bool = false
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.standardOutputTruncated = standardOutputTruncated
        self.standardErrorTruncated = standardErrorTruncated
    }
}

public protocol SandboxGuestCommandRuntime: Sendable {
    func execute(
        name: String,
        request: SandboxGuestCommandRequest
    ) async throws -> SandboxGuestCommandResult
}
