// Start preflight: the boot-security gate (SIP + Secure Boot must be fully on).
//
// Thin wiring only — the policy and the user-facing guidance live in
// ProviderCore (`BootSecurityPolicy`, `BootSecurityGuidance`) so they are pure,
// shared with `doctor`, and unit-testable without spawning processes.
import ArgumentParser
import Foundation
import ProviderCore

extension Start {
    /// Block startup unless macOS, SIP, and Secure Boot are all fully on.
    ///
    /// A confident failure (below the macOS 26 floor, SIP off / partial, or
    /// Secure Boot Reduced/Permissive) hard-fails after printing the enable
    /// guide. A state we genuinely can't determine (undetectable Secure Boot)
    /// only warns — we never want a false positive (e.g. a localized
    /// `system_profiler` value) to lock an otherwise-correct provider out of the
    /// network. The `DARKBLOOM_ALLOW_INSECURE_BOOT` escape hatch downgrades the
    /// hard-fail to a loud warning for developers on non-compliant machines.
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
}
