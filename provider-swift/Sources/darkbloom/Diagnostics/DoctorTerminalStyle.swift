import Darwin
import Foundation
import ProviderCore

/// ANSI color is presentation only. Pipes, dumb terminals and NO_COLOR retain
/// the exact plain-text report so scripts and support logs stay readable.
enum DoctorTerminalStyle {
    static func enabled(
        isTTY: Bool = isatty(STDOUT_FILENO) != 0,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        isTTY && environment["NO_COLOR"] == nil && environment["CLICOLOR"] != "0"
            && environment["TERM"] != "dumb"
    }

    static func marker(_ level: DiagnosticLevel, color: Bool) -> String {
        guard color else { return level.marker }
        let code: String
        switch level {
        case .fail: code = "1;31"
        case .warn: code = "1;33"
        case .pass: code = "1;32"
        case .info: code = "1;36"
        }
        return paint(level.marker, code: code)
    }

    static func heading(_ value: String, color: Bool) -> String {
        color ? paint(value, code: "1;36") : value
    }

    static func verdict(_ value: String, level: DiagnosticLevel, color: Bool) -> String {
        guard color else { return value }
        let code = level == .fail ? "1;31" : level == .warn ? "1;33" : "1;32"
        return paint(value, code: code)
    }

    private static func paint(_ value: String, code: String) -> String {
        "\u{001B}[\(code)m\(value)\u{001B}[0m"
    }
}
