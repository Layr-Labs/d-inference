import Foundation

public enum GuestProtocolError: Error, Equatable, Sendable {
    case invalidFrame, invalidMessage, unauthenticated, invalidSequence
    case disconnected, invalidConfiguration, busy, invalidPath, transferConflict
    case unavailable, cleanupUncertain, fileChanged
    case publicationUncertain
}

public enum GuestProtocolLimits {
    public static let version = 1
    public static let port: UInt32 = 7777
    public static let maximumFrameBytes = 8 * 1_048_576
    public static let maximumChunkBytes = 512 * 1_024
    public static let maximumOutputBytes = 1_048_576
}

/// The host's durable command journal supplies execution idempotency. Guest
/// sessions reject transport replay but do not invent exactly-once semantics.
public struct GuestRequest: Codable, Sendable, Equatable {
    public enum Operation: String, Codable, Sendable {
        case ping, execute, cancel, uploadBegin, uploadChunk, uploadCommit
        case uploadAbort, uploadStatus, download, mkdir
    }
    public let id: UUID
    public let operation: Operation
    public var command: GuestCommand?
    public var transferID: UUID?
    public var path: String?
    public var offset: UInt64?
    public var size: UInt64?
    public var data: Data?
    public var sha256: String?
    public var version: String?

    public init(id: UUID = UUID(), operation: Operation, command: GuestCommand? = nil,
                transferID: UUID? = nil, path: String? = nil, offset: UInt64? = nil,
                size: UInt64? = nil, data: Data? = nil, sha256: String? = nil, version: String? = nil) {
        self.id = id; self.operation = operation; self.command = command
        self.transferID = transferID; self.path = path; self.offset = offset
        self.size = size; self.data = data; self.sha256 = sha256; self.version = version
    }
}

public struct GuestCommand: Codable, Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    /// Relative to the bounded workspace. Empty means its root.
    public let workingDirectory: String
    public let timeoutSeconds: UInt32

    public init(executable: String, arguments: [String] = [],
                environment: [String: String] = [:], workingDirectory: String = "",
                timeoutSeconds: UInt32 = 900) {
        self.executable = executable; self.arguments = arguments
        self.environment = environment; self.workingDirectory = workingDirectory
        self.timeoutSeconds = timeoutSeconds
    }

    public func validate() throws {
        let bytes = executable.utf8.count + workingDirectory.utf8.count
            + arguments.reduce(0) { $0 + $1.utf8.count }
            + environment.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        let reserved: Set<String> = ["HOME", "PATH", "TMPDIR", "SHELL", "ENV", "BASH_ENV", "ZDOTDIR"]
        guard executable.hasPrefix("/"), executable.utf8.count <= 4096,
              !executable.contains("\0"), arguments.count <= 256, bytes <= 65536,
              arguments.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 16384 }),
              (1...900).contains(timeoutSeconds), environment.count <= 128,
              environment.allSatisfy({ key, value in
                  !key.isEmpty && key.utf8.count <= 128 && !key.contains("=")
                  && !key.contains("\0") && !value.contains("\0")
                  && !reserved.contains(key) && !key.hasPrefix("DYLD_")
                  && !key.hasPrefix("DARKBLOOM_") && value.utf8.count <= 16384
              }) else { throw GuestProtocolError.invalidMessage }
        _ = try GuestPath.components(workingDirectory, allowRoot: true)
    }
}

public enum GuestPath {
    public static func components(_ path: String, allowRoot: Bool = false) throws -> [String] {
        if path.isEmpty && allowRoot { return [] }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              path.utf8.count <= 4096,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 })
        else { throw GuestProtocolError.invalidPath }
        return parts
    }
}

public struct GuestResponse: Codable, Sendable, Equatable {
    public let id: UUID
    public let success: Bool
    public var errorCode: String?
    public var exitCode: Int32?
    public var standardOutput: Data?
    public var standardError: Data?
    public var standardOutputTruncated: Bool?
    public var standardErrorTruncated: Bool?
    public var timedOut: Bool?
    public var cancelled: Bool?
    /// The host must stop the whole VM before reporting successful cancellation
    /// or starting another job when guest descendant cleanup is unproven.
    public var requiresVMStop: Bool?
    public var data: Data?
    public var offset: UInt64?
    public var size: UInt64?
    public var sha256: String?
    public var version: String?
    public var upload: GuestUploadStatus?
    public var transferID: UUID?
    public var state: GuestTransferState?

    public init(id: UUID, success: Bool, errorCode: String? = nil) {
        self.id = id; self.success = success; self.errorCode = errorCode
    }
}

public enum GuestTransferState: String, Codable, Sendable {
    case uploading, committed, aborted
}

public struct GuestUploadStatus: Codable, Sendable, Equatable {
    public let path: String
    public let size: UInt64
    public let sha256: String
    public let offset: UInt64
    public let state: GuestTransferState
    public var committed: Bool { state == .committed }

    public init(path: String, size: UInt64, sha256: String, offset: UInt64, committed: Bool) {
        self.path = path; self.size = size; self.sha256 = sha256
        self.offset = offset; self.state = committed ? .committed : .uploading
    }

    public init(path: String, size: UInt64, sha256: String, offset: UInt64, state: GuestTransferState) {
        self.path = path; self.size = size; self.sha256 = sha256
        self.offset = offset; self.state = state
    }
}
