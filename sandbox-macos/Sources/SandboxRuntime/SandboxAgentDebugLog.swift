import Dispatch
import Foundation

public enum SandboxAgentDebugLog {
    private static let lock = NSLock()

    public static func write(
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: Any]
    ) {
        var timedData = data
        timedData["uptimeNanoseconds"] = String(
            DispatchTime.now().uptimeNanoseconds
        )
        let payload: [String: Any] = [
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "data": timedData,
            "timestamp": Int64(Date().timeIntervalSince1970 * 1_000),
        ]
        guard let encoded = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        ) else {
            return
        }
        let path = ProcessInfo.processInfo.environment[
            "DARKBLOOM_SANDBOX_DEBUG_LOG"
        ] ?? "/opt/cursor/logs/debug.log"

        lock.lock()
        defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: path) {
            _ = FileManager.default.createFile(
                atPath: path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        guard let handle = FileHandle(forWritingAtPath: path) else {
            return
        }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: encoded + Data([0x0A]))
    }

    public static func output(
        _ data: Data,
        redacting values: [String]
    ) -> [String: Any] {
        let original = String(decoding: data, as: UTF8.self)
        var sanitized = original
        for value in values
            .filter({ !$0.isEmpty })
            .sorted(by: { $0.count > $1.count })
        {
            sanitized = sanitized.replacingOccurrences(
                of: value,
                with: "<redacted-path>"
            )
        }
        sanitized = sanitized.replacingOccurrences(
            of: #"vnc://[^\s"\\]+"#,
            with: "<redacted-vnc-url>",
            options: .regularExpression
        )
        let sanitizedData = Data(sanitized.utf8)
        return [
            "base64": sanitizedData.base64EncodedString(),
            "byteCount": data.count,
            "redacted": sanitized != original,
            "utf8": sanitized,
            "validUTF8": String(data: data, encoding: .utf8) != nil,
        ]
    }
}
