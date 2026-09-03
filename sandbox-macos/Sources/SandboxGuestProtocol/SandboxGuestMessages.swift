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
    public static let maximumEnvironmentKeyBytes = 128
    public static let maximumAggregateInputBytes = 65_536

    /// Environment keys a command may never set for itself.
    ///
    /// These mirror `SandboxGuestCommandRequest` on the host exactly. The host
    /// rejects them at construction, so a request carrying one is either a
    /// buggy host or a hostile peer — either way the agent refuses rather than
    /// silently overriding, because the agent cannot trust the channel.
    public static func isReservedEnvironmentKey(_ key: String) -> Bool {
        switch key {
        case "BASH_ENV", "ENV", "HOME", "LANG", "LC_ALL", "PATH",
             "TMPDIR", "ZDOTDIR":
            return true
        default:
            return key.hasPrefix("DARKBLOOM_") || key.hasPrefix("DYLD_")
        }
    }

    /// `[A-Za-z_][A-Za-z0-9_]*`, matching the host's validator.
    public static func isValidEnvironmentKey(_ key: String) -> Bool {
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
}

// MARK: - Handshake

public struct SandboxGuestHandshake: Codable, Equatable, Sendable {
    public static let magic = "darkbloom_guest_agent"
    public static let currentProtocolVersion: UInt16 = 1

    public let magic: String
    public let protocolVersion: UInt16
    public let agentVersion: String
    public let imageID: String

    /// Whether this agent will actually run commands, or refuse every one.
    ///
    /// The agent's executor is gated independently of anything the host knows,
    /// so a channel existing says nothing about whether commands sent down it
    /// will be served. Advertising it here lets the host route on a fact
    /// instead of an assumption: an agent that refuses is still worth a
    /// channel, because the handshake is what proves the image, but commands
    /// have to go the other way.
    public let executionEnabled: Bool

    public init(
        magic: String = SandboxGuestHandshake.magic,
        protocolVersion: UInt16 = SandboxGuestHandshake.currentProtocolVersion,
        agentVersion: String,
        imageID: String,
        executionEnabled: Bool = false
    ) {
        self.magic = magic
        self.protocolVersion = protocolVersion
        self.agentVersion = agentVersion
        self.imageID = imageID
        self.executionEnabled = executionEnabled
    }

    /// Decoded leniently for this one field so an agent baked before it
    /// existed still handshakes, and is read as refusing -- which is what such
    /// an agent does.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.magic = try container.decode(String.self, forKey: .magic)
        self.protocolVersion = try container.decode(
            UInt16.self, forKey: .protocolVersion)
        self.agentVersion = try container.decode(
            String.self, forKey: .agentVersion)
        self.imageID = try container.decode(String.self, forKey: .imageID)
        self.executionEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .executionEnabled) ?? false
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
        case executionEnabled = "execution_enabled"
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

    /// Guest-side validation, applied before anything is spawned.
    ///
    /// This must be at least as strict as the host's
    /// `SandboxGuestCommandRequest`, never weaker: the agent re-checks
    /// precisely because it cannot trust the channel, and a validator that
    /// admits more than the host would let a hostile peer reach the spawn with
    /// a request the host itself would have refused.
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
                SandboxGuestLimits.isValidEnvironmentKey(key)
                    && !SandboxGuestLimits.isReservedEnvironmentKey(key)
                    && key.utf8.count
                        <= SandboxGuestLimits.maximumEnvironmentKeyBytes
                    && !value.contains("\0")
                    && value.utf8.count <= SandboxGuestLimits.maximumValueBytes
            }
            && aggregateInputBytes
                <= SandboxGuestLimits.maximumAggregateInputBytes
            && !idempotencyKey.isEmpty
            && !idempotencyKey.contains("\0")
            && idempotencyKey.utf8.count
                <= SandboxGuestLimits.maximumValueBytes
    }

    /// Same accounting the host applies, so an oversized request cannot reach
    /// `posix_spawn` and fail as an opaque `E2BIG`.
    public var aggregateInputBytes: Int {
        executable.utf8.count
            + workingDirectory.utf8.count
            + arguments.reduce(0) { $0 + $1.utf8.count }
            + environment.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
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
