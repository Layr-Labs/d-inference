import Foundation
import SandboxRuntime

/// Only runtime management commands use this diagnostic. Guest job output has
/// its own payload path and must never be copied into operator error logs.
enum LumeControlDiagnostic {
    static func failure(_ result: SandboxProcessResult) -> String {
        let stderr = String(decoding: result.standardError.prefix(4096), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        // Some pinned Lume failures report their message through the logger on
        // stdout and exit70 with empty stderr. Keep a bounded explanation.
        let stdout = String(decoding: result.standardOutput.suffix(4096), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stdout.isEmpty ? "runtime exited without a diagnostic" : stdout
    }
}
