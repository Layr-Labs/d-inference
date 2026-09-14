import Foundation
import SandboxRuntime

/// Base provisioning runs only fixed operator-owned code before tenant data or
/// per-instance credentials exist. Its bounded stderr is useful setup evidence;
/// general guest command output remains outside operator diagnostics.
struct BaseGuestInstallationFailure: Error, CustomStringConvertible {
    let exitCode: Int32
    let timedOut: Bool
    let diagnostic: String

    init(result: SandboxGuestCommandResult) {
        exitCode = result.exitCode
        timedOut = result.timedOut
        let captured = String(decoding: result.standardError.prefix(4096), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        diagnostic = captured.isEmpty ? "no guest installation diagnostic" : captured
    }

    var description: String {
        "signed guest installation failed (exit \(exitCode), timeout \(timedOut)): \(diagnostic)"
    }
}
