import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// #region agent log support
public enum AgentDebugLog {
    public static func write(
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: Any]
    ) {
        let payload: [String: Any] = [
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "data": data,
            "timestamp": Int(Date().timeIntervalSince1970 * 1_000),
        ]
        guard var encoded = try? JSONSerialization.data(withJSONObject: payload) else {
            return
        }
        encoded.append(0x0A)

        let path = "/opt/cursor/logs/debug.log"
        #if canImport(Darwin)
        let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND, mode_t(0o600))
        #elseif canImport(Glibc)
        let descriptor = Glibc.open(path, O_WRONLY | O_CREAT | O_APPEND, mode_t(0o600))
        #else
        return
        #endif
        guard descriptor >= 0 else { return }
        defer {
            #if canImport(Darwin)
            _ = Darwin.close(descriptor)
            #elseif canImport(Glibc)
            _ = Glibc.close(descriptor)
            #endif
        }
        encoded.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            #if canImport(Darwin)
            _ = Darwin.write(descriptor, baseAddress, bytes.count)
            #elseif canImport(Glibc)
            _ = Glibc.write(descriptor, baseAddress, bytes.count)
            #endif
        }
    }
}
// #endregion
