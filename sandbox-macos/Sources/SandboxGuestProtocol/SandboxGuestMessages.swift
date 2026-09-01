import Foundation

/// Payloads carried inside `SandboxGuestFrame`.
///
/// The result envelope is deliberately identical to the one the launchd/SSH
/// bootstrap path already produces: same magic, same schema version, same
/// snake_case keys, same base64 streams and length cross-checks. Keeping the
/// format means `LumeGuestCommandJournal` — which persists raw envelope bytes
/// and re-validates them on read — is untouched by the transport change. The
/// transport moves; the format does not.

public enum SandboxGuestLimits {
    /// Matches the bootstrap path's per-stream cap.
    public static let maximumStreamBytes = 1_048_576
    public static let maximumArgumentCount = 256
    public static let maximumEnvironmentVariableCount = 128
    public static let maximumPathBytes = 4_096
    public static let maximumValueBytes = 16_384
}

// MARK: - Handshake

public struct SandboxGuestHandshake: Codable, Equatable, Sendable {
    public static let magic = "darkbloom_guest_agent"
    public static let currentProtocolVersion: UInt16 = 1

    public let magic: String
    public let protocolVersion: UInt16
    public let agentVersion: String
    public let imageID: String

    public init(
        magic: String = SandboxGuestHandshake.magic,
        protocolVersion: UInt16 = SandboxGuestHandshake.currentProtocolVersion,
        agentVersion: String,
        imageID: String
    ) {
        self.magic = magic
        self.protocolVersion = protocolVersion
        self.agentVersion = agentVersion
        self.imageID = imageID
    }

    /// Host-side validation. A handshake that does not satisfy this is a
    /// failed readiness check, not a warning.
    public func isAcceptable(expectedImageID: String?) -> Bool {
        guard magic == Self.magic,
              protocolVersion == Self.currentProtocolVersion,
              !agentVersion.isEmpty
        else {
            return false
        }
        guard let expectedImageID else {
            return true
        }
        return imageID == expectedImageID
    }

    private enum CodingKeys: String, CodingKey {
        case magic
        case protocolVersion = "protocol_version"
        case agentVersion = "agent_version"
        case imageID = "image_id"
    }
}

// MARK: - Command request

public struct SandboxGuestCommandWire: Codable, Equatable, Sendable {
    public let idempotencyKey: String
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: String
    public let timeoutSeconds: UInt32

    public init(
        idempotencyKey: String,
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String,
        timeoutSeconds: UInt32
    ) {
        self.idempotencyKey = idempotencyKey
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeoutSeconds = timeoutSeconds
    }

    /// Guest-side validation, applied before anything is spawned. The host
    /// validates the same shape in `SandboxGuestCommandRequest`; the agent
    /// re-checks because it must not trust the channel either.
    public var isWellFormed: Bool {
        executable.hasPrefix("/")
            && !executable.contains("\0")
            && executable.utf8.count <= SandboxGuestLimits.maximumPathBytes
            && workingDirectory.hasPrefix("/")
            && !workingDirectory.contains("\0")
            && workingDirectory.utf8.count <= SandboxGuestLimits.maximumPathBytes
            && (1...900).contains(timeoutSeconds)
            && arguments.count <= SandboxGuestLimits.maximumArgumentCount
            && arguments.allSatisfy {
                !$0.contains("\0")
                    && $0.utf8.count <= SandboxGuestLimits.maximumValueBytes
            }
            && environment.count
                <= SandboxGuestLimits.maximumEnvironmentVariableCount
            && environment.allSatisfy { key, value in
                !key.isEmpty
                    && !key.contains("=")
                    && !key.contains("\0")
                    && !value.contains("\0")
                    && value.utf8.count <= SandboxGuestLimits.maximumValueBytes
            }
            && !idempotencyKey.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case idempotencyKey = "idempotency_key"
        case executable
        case arguments
        case environment
        case workingDirectory = "working_directory"
        case timeoutSeconds = "timeout_seconds"
    }
}

// MARK: - Result envelope

/// Byte-compatible mirror of the bootstrap path's result envelope.
public struct SandboxGuestResultEnvelope: Codable, Equatable, Sendable {
    public static let magic = "darkbloom_guest_result"
    public static let schemaVersion: UInt16 = 2

    public let magic: String
    public let schemaVersion: UInt16
    public let exitCode: Int32
    public let standardOutputLength: Int
    public let standardErrorLength: Int
    public let standardOutputTruncated: Bool
    public let standardErrorTruncated: Bool
    public let timedOut: Bool
    public let standardOutput: Data
    public let standardError: Data

    public init(
        exitCode: Int32,
        standardOutput: Data,
        standardError: Data,
        standardOutputTruncated: Bool,
        standardErrorTruncated: Bool,
        timedOut: Bool
    ) {
        magic = Self.magic
        schemaVersion = Self.schemaVersion
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        standardOutputLength = standardOutput.count
        standardErrorLength = standardError.count
        self.standardOutputTruncated = standardOutputTruncated
        self.standardErrorTruncated = standardErrorTruncated
        self.timedOut = timedOut
    }

    /// The same invariants the host decoder enforces, so the agent cannot emit
    /// an envelope its own host would reject.
    public var isSelfConsistent: Bool {
        magic == Self.magic
            && schemaVersion == Self.schemaVersion
            && (0...255).contains(exitCode)
            && (!timedOut || exitCode == 124)
            && standardOutput.count == standardOutputLength
            && standardError.count == standardErrorLength
            && standardOutput.count <= SandboxGuestLimits.maximumStreamBytes
            && standardError.count <= SandboxGuestLimits.maximumStreamBytes
    }

    private enum CodingKeys: String, CodingKey {
        case magic
        case schemaVersion = "schema_version"
        case exitCode = "exit_code"
        case standardOutputLength = "stdout_length"
        case standardErrorLength = "stderr_length"
        case standardOutputTruncated = "stdout_truncated"
        case standardErrorTruncated = "stderr_truncated"
        case timedOut = "timed_out"
        case standardOutput = "stdout_base64"
        case standardError = "stderr_base64"
    }
}

// MARK: - Failure

public struct SandboxGuestFailure: Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}
