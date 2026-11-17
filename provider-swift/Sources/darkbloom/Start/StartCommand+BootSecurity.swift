import ArgumentParser
import ProviderCore

extension Start {
    /// In the Darkbloom serving modes (`coordinatorEnforced`) a boot security
    /// refusal is printed as one; every other issue, and every issue of Only
    /// me, is a warning the start continues past.
    func warnBootSecurity(
        snapshot: BootSecuritySnapshot = .live(),
        coordinatorEnforced: Bool,
        emit: (String) -> Void = { printError($0) }
    ) {
        let refusals = coordinatorEnforced ? snapshot.servingRefusals : []
        if !refusals.isEmpty {
            emit("Darkbloom serving stays off on this Mac until its boot security is at Apple's default.")
            emitBootSecurityIssues(refusals, emit: emit)
            emit("  Only me (`\(BuildEnvironment.current.cliName) start --local`) still serves your own requests.")
        }
        let warnings = snapshot.issues.filter { !refusals.contains($0) }
        guard !warnings.isEmpty else { return }
        if !refusals.isEmpty {
            emit("WARNING: local boot security also needs attention.")
        } else {
            let enforcement = coordinatorEnforced
                ? " Coordinator trust policy still controls public routing."
                : ""
            emit("WARNING: local boot security needs attention; continuing.\(enforcement)")
        }
        emitBootSecurityIssues(warnings, emit: emit)
    }

    /// `start`'s preflight for the Darkbloom serving modes: refuse before any
    /// prompt or download when this Mac could not serve.
    func refuseUnservableBootSecurity(
        snapshot: BootSecuritySnapshot = .live(),
        emit: (String) -> Void = { printError($0) }
    ) throws {
        warnBootSecurity(snapshot: snapshot, coordinatorEnforced: true, emit: emit)
        guard snapshot.servingRefusals.isEmpty else { throw ExitCode.failure }
    }

    private func emitBootSecurityIssues(_ issues: [BootSecurityIssue], emit: (String) -> Void) {
        for issue in issues {
            emit("  - \(issue.name): \(issue.detail)")
            emit("    Fix: \(issue.fix)")
        }
    }

    func bootSecurityTelemetryFields(_ snapshot: BootSecuritySnapshot) -> [String: AnyCodableValue] {
        [
            "boot_macos_major": .int(snapshot.macOSMajorVersion),
            "boot_sip_status": .string(snapshot.sip.telemetryValue),
        ]
    }
}
