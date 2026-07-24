import ProviderCore

extension Start {
    func warnBootSecurity(
        snapshot: BootSecuritySnapshot = .live(),
        coordinatorEnforced: Bool,
        emit: (String) -> Void = { printError($0) }
    ) {
        guard !snapshot.issues.isEmpty else { return }
        let enforcement = coordinatorEnforced
            ? " Coordinator trust policy still controls public routing."
            : ""
        emit("WARNING: local boot security needs attention; continuing.\(enforcement)")
        for issue in snapshot.issues {
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
