import Foundation
import SandboxRuntime

package enum LumeRuntimeDebugLog {
    private static let lock = NSLock()

    package static func write(
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: String]
    ) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DARKBLOOM_SANDBOX_DEBUG_LOG"] == "1" else {
            return
        }
        let path = environment["DARKBLOOM_SANDBOX_DEBUG_LOG_PATH"]
            ?? "/opt/cursor/logs/debug.log"
        let entry = Entry(
            hypothesisId: hypothesisId,
            location: location,
            message: message,
            data: data,
            timestamp: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        guard let encoded = try? JSONEncoder().encode(entry) else {
            return
        }

        lock.lock()
        defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(
                atPath: path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                return
            }
        }
        guard let handle = try? FileHandle(
            forWritingTo: URL(fileURLWithPath: path)
        ) else {
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: encoded + Data([0x0A]))
        } catch {
            return
        }
    }

    package static func virtualMachineRole(_ name: String) -> String {
        if name.hasPrefix("darkbloom-phase0-a-") {
            return "clone-a"
        }
        if name.hasPrefix("darkbloom-phase0-b-") {
            return "clone-b"
        }
        return "other"
    }

    package static func executableRole(_ executable: String) -> String {
        switch executable {
        case "/bin/zsh":
            return "zsh"
        case "/bin/test":
            return "test"
        case "/bin/rm":
            return "rm"
        case "/usr/bin/touch":
            return "touch"
        default:
            return "other"
        }
    }

    package static func errorData(_ error: Error) -> [String: String] {
        if error is CancellationError {
            return ["kind": "cancellation"]
        }
        if error is LumeGuestReadinessDeadlineExceeded {
            return ["kind": "readiness-deadline"]
        }
        guard let runtimeError = error as? SandboxRuntimeError else {
            return [
                "kind": "other",
                "type": String(reflecting: type(of: error)),
            ]
        }
        switch runtimeError {
        case .commandFailed(let command, let exitCode, let standardError):
            return [
                "kind": "command-failed",
                "command": command,
                "exitCode": String(exitCode),
                "sshOperationTimedOut":
                    String(standardError.contains("SSH operation timed out")),
            ]
        case .operationTimedOut:
            return ["kind": "operation-timed-out"]
        case .cleanupFailed:
            return ["kind": "cleanup-failed"]
        case .invalidName:
            return ["kind": "invalid-name"]
        case .invalidImageReference:
            return ["kind": "invalid-image-reference"]
        case .diskSmallerThanWorkspace:
            return ["kind": "disk-smaller-than-workspace"]
        case .executableNotFound:
            return ["kind": "executable-not-found"]
        case .operationInProgress:
            return ["kind": "operation-in-progress"]
        case .malformedOutput:
            return ["kind": "malformed-output"]
        case .unsupported:
            return ["kind": "unsupported"]
        }
    }

    private struct Entry: Encodable {
        let hypothesisId: String
        let location: String
        let message: String
        let data: [String: String]
        let timestamp: Int64
    }
}
