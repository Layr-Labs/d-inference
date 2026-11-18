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
            emit(Self.servingOffBanner(refusals))
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

    /// Whether a start stops before its setup (the schedule wizard, saved
    /// settings, the runtime): only one that installs the Darkbloom service on
    /// a Mac that can't serve. A service's child holds instead (the serve
    /// loop), and Only me only warns.
    static func refusesBeforeSetup(_ path: SingleMacServing, bootSecurity: BootSecuritySnapshot) -> Bool {
        path == .service && !bootSecurity.servingRefusals.isEmpty
    }

    /// A sandbox Darkbloom didn't set up says nothing about the Mac's boot
    /// settings, only that Darkbloom can't verify them from there.
    static func servingOffBanner(_ refusals: [BootSecurityIssue]) -> String {
        let sandboxed = refusals.contains { $0.kind == .processSandbox }
        if !sandboxed { return "Darkbloom serving stays off on this Mac until its boot security is at Apple's default." }
        return refusals.allSatisfy { $0.kind == .processSandbox }
            ? "Darkbloom serving stays off while Darkbloom can't verify this Mac's boot security."
            : "Darkbloom serving stays off on this Mac until the issues below are resolved."
    }

    func bootSecurityTelemetryFields(_ snapshot: BootSecuritySnapshot) -> [String: AnyCodableValue] {
        [
            "boot_macos_major": .int(snapshot.macOSMajorVersion),
            "boot_sip_status": .string(snapshot.sip.telemetryValue),
            "boot_process_sandbox": .string(snapshot.processSandbox.telemetryValue),
        ]
    }
}
