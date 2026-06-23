import Foundation

// MARK: - Verdict

/// The gate verdict for a single boot-security protection.
public enum BootSecurityVerdict: Sendable, Equatable {
    /// Fully on — acceptable.
    case pass
    /// Could not be determined — surface a warning, but do not block.
    case warn
    /// Confidently not fully on — block startup.
    case fail
}

// MARK: - Status summaries (shared wording)

extension SIPStatus {
    /// One-line, human-readable summary of the SIP state, shared by the doctor
    /// check detail and the start-preflight warning so the wording never drifts.
    public var summary: String {
        switch self {
        case .enabled:
            return "enabled (full protection)"
        case .disabled:
            return "disabled"
        case .enabledWithCustomConfiguration(let disabledProtections):
            let base = "enabled (Custom Configuration) — NOT fully enabled"
            guard !disabledProtections.isEmpty else { return base }
            return "\(base); disabled: \(disabledProtections.joined(separator: ", "))"
        case .unavailable(let reason):
            return "could not determine (\(reason))"
        case .unrecognized(let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "could not interpret csrutil output (\(trimmed))"
        }
    }
}

extension SecureBootStatus {
    /// One-line, human-readable summary of the Secure Boot state, shared by the
    /// doctor check detail and the start-preflight warning.
    public var summary: String {
        switch self {
        case .fullSecurity:
            return "Full Security"
        case .reduced:
            return "Reduced/Medium Security (system_profiler ibridge_secure_boot) "
                + "— NOT Full Security"
        case .permissiveOrDisabled:
            return "Permissive / No Security (system_profiler ibridge_secure_boot) "
                + "— secure boot not enforced"
        case .unavailable(let reason):
            return "could not determine (\(reason)) — the coordinator still requires "
                + "confirmed Secure Boot, so proceeding locally does not guarantee admission"
        }
    }
}

// MARK: - Policy

/// Pure policy that maps detected boot-security states to gate verdicts and to
/// the combined `start` preflight decision. Free of any process/IO so it is
/// fully unit-testable.
public enum BootSecurityPolicy {
    /// Environment variable that downgrades a hard failure to a loud warning.
    /// Documented developer escape hatch so engineers on non-Full-Security
    /// machines aren't locked out; never for production use.
    public static let overrideEnvVar = "DARKBLOOM_ALLOW_INSECURE_BOOT"

    /// The minimum supported macOS major version. macOS 26 (Tahoe) is the floor:
    /// it is what makes `system_profiler SPiBridgeDataType` a reliable, sudo-free
    /// Secure Boot signal, and it is the only OS the provider is validated on.
    public static let minimumMacOSMajorVersion = 26

    /// macOS version gate: the running major version must be at least
    /// `minimumMacOSMajorVersion`. Always determinable (read from `ProcessInfo`),
    /// so there is no `.warn` case — below the floor is a hard `.fail`.
    public static func macOSVerdict(_ majorVersion: Int) -> BootSecurityVerdict {
        majorVersion >= minimumMacOSMajorVersion ? .pass : .fail
    }

    /// One-line, human-readable summary of the macOS version state, shared by
    /// the doctor check detail and the start-preflight message.
    public static func macOSSummary(majorVersion: Int) -> String {
        if majorVersion >= minimumMacOSMajorVersion {
            return "macOS \(majorVersion) — meets the macOS \(minimumMacOSMajorVersion) (Tahoe) minimum"
        }
        return "macOS \(majorVersion) — below the required macOS \(minimumMacOSMajorVersion) "
            + "(Tahoe); update to continue"
    }

    /// SIP gate: fully enabled passes; disabled or "enabled (Custom
    /// Configuration)" fail (custom config is NOT fully enabled); an
    /// undeterminable result warns rather than blocks (csrutil should always be
    /// present, so this is the pathological case — warn to avoid false lockout).
    public static func sipVerdict(_ status: SIPStatus) -> BootSecurityVerdict {
        switch status {
        case .enabled:
            return .pass
        case .disabled, .enabledWithCustomConfiguration:
            return .fail
        case .unavailable, .unrecognized:
            return .warn
        }
    }

    /// Secure Boot gate: provable Full Security (`ibridge_secure_boot == "Full
    /// Security"`, Apple Silicon or Intel T2) passes; a confidently-reported
    /// downgrade (Reduced/Medium/Permissive/No Security) fails; an undeterminable
    /// posture warns rather than blocks (avoids false-positive lockouts on a
    /// localized `system_profiler` value or an unreadable probe).
    ///
    /// `pass` and `attestsSecureBoot` derive from the SAME `SecureBootStatus`, so
    /// the gate and the attested `secure_boot_enabled` never disagree.
    public static func secureBootVerdict(_ status: SecureBootStatus) -> BootSecurityVerdict {
        switch status {
        case .fullSecurity:
            return .pass
        case .reduced, .permissiveOrDisabled:
            return .fail
        case .unavailable:
            return .warn
        }
    }

    // MARK: - Combined preflight decision

    /// Outcome of evaluating both protections for the `start` preflight: whether
    /// to block, the exact lines to print, and whether a block was overridden.
    public struct PreflightDecision: Sendable, Equatable {
        /// True when `start` must abort (throw a non-zero exit).
        public let shouldBlock: Bool
        /// Ordered lines to print (warnings + the enable guide). Empty when all
        /// protections pass.
        public let messageLines: [String]
        /// True when a confident failure was downgraded to a warning by the
        /// escape-hatch env var.
        public let overrodeBlock: Bool

        public init(shouldBlock: Bool, messageLines: [String], overrodeBlock: Bool) {
            self.shouldBlock = shouldBlock
            self.messageLines = messageLines
            self.overrodeBlock = overrodeBlock
        }

        /// All protections passed: nothing to print, nothing to block.
        public static let ok = PreflightDecision(shouldBlock: false, messageLines: [], overrodeBlock: false)
    }

    /// Evaluate all three protections and produce the preflight decision.
    ///
    /// - Failure (below the macOS floor, or a confident SIP / Secure Boot
    ///   downgrade) blocks startup unless `allowInsecureOverride` is set, in
    ///   which case it is loudly downgraded to a warning.
    /// - A warning (undeterminable Secure Boot) prints the guide but never
    ///   blocks, so an undetectable host is not falsely locked out.
    public static func preflightDecision(
        macOSMajorVersion: Int,
        sip: SIPStatus,
        secureBoot: SecureBootStatus,
        allowInsecureOverride: Bool
    ) -> PreflightDecision {
        let macOSV = macOSVerdict(macOSMajorVersion)
        let sipV = sipVerdict(sip)
        let secureBootV = secureBootVerdict(secureBoot)
        guard macOSV != .pass || sipV != .pass || secureBootV != .pass else {
            return .ok
        }

        let hasFailure = macOSV == .fail || sipV == .fail || secureBootV == .fail

        var lines: [String] = []
        lines.append(
            hasFailure
                ? "ERROR: macOS boot security is not fully enabled — required to serve inference."
                : "WARNING: macOS boot security could not be fully verified."
        )
        if macOSV != .pass {
            lines.append("  - macOS version: \(macOSSummary(majorVersion: macOSMajorVersion))")
        }
        if sipV != .pass {
            lines.append("  - System Integrity Protection (SIP): \(sip.summary)")
        }
        if secureBootV != .pass {
            lines.append("  - Secure Boot: \(secureBoot.summary)")
        }
        lines.append("")
        lines.append(BootSecurityGuidance.guide(
            includeMacOS: macOSV != .pass,
            includeSIP: sipV != .pass,
            includeSecureBoot: secureBootV != .pass
        ))

        if hasFailure && allowInsecureOverride {
            lines.append("")
            lines.append("\(overrideEnvVar)=1 is set — continuing despite the failure above.")
            lines.append("This is for development only. DO NOT serve production traffic like this.")
            return PreflightDecision(shouldBlock: false, messageLines: lines, overrodeBlock: true)
        }

        if hasFailure {
            lines.append("")
            lines.append("Refusing to start. Fix the above, or set \(overrideEnvVar)=1 to override (developer use only).")
            return PreflightDecision(shouldBlock: true, messageLines: lines, overrodeBlock: false)
        }

        // Warnings only (state genuinely undeterminable): surface the guide but
        // let startup proceed so we never lock out a correctly configured host.
        return PreflightDecision(shouldBlock: false, messageLines: lines, overrodeBlock: false)
    }
}
