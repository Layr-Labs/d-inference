import DarkbloomProcessHardening
import Foundation
import ProviderCore

/// `main` removes the debugging handles this process was started with before
/// anything else (`ProcessStartupHardening`). If one could not be removed, the
/// process runs only the read-only diagnostics that explain it: no serving,
/// worker, key, account or model command starts.
enum StartupHardeningGate {
    static let diagnostics: Set<String> = ["doctor", "verify", "status", "logs", "--version", "--help", "-h", "help"]

    static func admits(_ arguments: [String], outcome: ProcessStartupHardening.Outcome) -> Bool {
        guard !outcome.isClean else { return true }
        // A bare invocation prints the root help.
        guard let command = arguments.first else { return true }
        return diagnostics.contains(command)
    }

    static var refusal: String {
        let cli = BuildEnvironment.current.cliName
        return "\(cli): \(ProcessStartupHardening.Refusal.handlersRemain). Run `\(cli) doctor` for details."
    }

    /// Exits with the refusal unless `admits`; returns otherwise.
    static func enforce(_ arguments: [String], outcome: ProcessStartupHardening.Outcome) {
        guard !admits(arguments, outcome: outcome) else { return }
        FileHandle.standardError.write(Data((refusal + "\n").utf8))
        exit(EXIT_FAILURE)
    }

    /// The doctor line: this command's own process went through the same
    /// removal as a serving one.
    static func doctorCheck(_ outcome: ProcessStartupHardening.Outcome?) -> DoctorCheck {
        guard let outcome, outcome.isClean else {
            return .init(name: "startup hardening", status: .fail,
                         detail: "could not clear the debugging handles this process was started with; this Mac will not serve")
        }
        return .init(name: "startup hardening", status: .pass, detail: "inherited debugging handles cleared")
    }
}
