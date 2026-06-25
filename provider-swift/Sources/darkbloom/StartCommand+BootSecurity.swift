// Start preflight: boot-security posture warning and telemetry.
//
// Thin wiring only — the policy and the user-facing guidance live in
// ProviderCore (`BootSecurityPolicy`, `BootSecurityGuidance`) so they are pure,
// shared with `doctor`, and unit-testable without spawning processes.
import ArgumentParser
import Foundation
import ProviderCore

extension Start {
    /// Warn unless macOS, SIP, and Secure Boot are all fully on.
    ///
    /// This is intentionally non-blocking during rollout: the provider reports
    /// posture through telemetry and the coordinator's MDM path enforces hardware
    /// trust for public routing.
    internal func enforceBootSecurity(
        snapshot: BootSecuritySnapshot = .live(),
        allowInsecureOverride: Bool = Start.allowInsecureBootOverride(),
        emit: (String) -> Void = { printError($0) }
    ) throws {
        let decision = BootSecurityPolicy.preflightDecision(
            macOSMajorVersion: snapshot.macOSMajorVersion,
            sip: snapshot.sip,
            secureBoot: snapshot.secureBoot,
            allowInsecureOverride: allowInsecureOverride
        )

        for line in decision.messageLines {
            emit(line)
        }

        if decision.shouldBlock {
            throw ExitCode.failure
        }
    }

    /// Whether the documented escape-hatch env var is set to a truthy value.
    static func allowInsecureBootOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = environment[BootSecurityPolicy.overrideEnvVar] else { return false }
        return ["1", "true", "yes"].contains(raw.trimmingCharacters(in: .whitespaces).lowercased())
    }

    func bootSecurityTelemetryFields(_ snapshot: BootSecuritySnapshot) -> [String: AnyCodableValue] {
        [
            "boot_macos_major": .int(snapshot.macOSMajorVersion),
            "boot_macos_verdict": .string(verdictName(BootSecurityPolicy.macOSVerdict(snapshot.macOSMajorVersion))),
            "boot_sip_status": .string(sipStatusName(snapshot.sip)),
            "boot_sip_verdict": .string(verdictName(BootSecurityPolicy.sipVerdict(snapshot.sip))),
            "boot_secure_boot_status": .string(secureBootStatusName(snapshot.secureBoot)),
            "boot_secure_boot_verdict": .string(verdictName(BootSecurityPolicy.secureBootVerdict(snapshot.secureBoot))),
        ]
    }

    func bootSecurityTelemetrySeverity(_ snapshot: BootSecuritySnapshot) -> TelemetrySeverity {
        if BootSecurityPolicy.macOSVerdict(snapshot.macOSMajorVersion) == .pass,
           BootSecurityPolicy.sipVerdict(snapshot.sip) == .pass,
           BootSecurityPolicy.secureBootVerdict(snapshot.secureBoot) == .pass {
            return .info
        }
        return .warn
    }

    private func verdictName(_ verdict: BootSecurityVerdict) -> String {
        switch verdict {
        case .pass:
            return "pass"
        case .warn:
            return "warn"
        case .fail:
            return "fail"
        }
    }

    private func sipStatusName(_ status: SIPStatus) -> String {
        switch status {
        case .enabled:
            return "enabled"
        case .disabled:
            return "disabled"
        case .enabledWithCustomConfiguration:
            return "custom_configuration"
        case .unavailable:
            return "unavailable"
        case .unrecognized:
            return "unrecognized"
        }
    }

    private func secureBootStatusName(_ status: SecureBootStatus) -> String {
        switch status {
        case .fullSecurity:
            return "full_security"
        case .reduced:
            return "reduced"
        case .permissiveOrDisabled:
            return "permissive_or_disabled"
        case .unavailable:
            return "unavailable"
        }
    }
}
