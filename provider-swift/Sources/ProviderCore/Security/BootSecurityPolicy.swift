import Foundation

// MARK: - Verdict

/// The rollout verdict for a single boot-security protection.
public enum BootSecurityVerdict: Sendable, Equatable {
    /// Fully on — acceptable.
    case pass
    /// Non-fatal advisory state for checks that can safely proceed with notice.
    case warn
    /// Confidently not fully on. Retained for policy consumers that still need
    /// a hard-fail signal; provider startup currently reports warnings only.
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
            return "could not determine (\(reason)) — confirmed Secure Boot is required for hardware trust"
        }
    }
}

// MARK: - Policy

/// Pure policy that maps detected boot-security states to rollout verdicts and to
/// the combined `start` preflight decision. Free of any process/IO so it is
/// fully unit-testable.
public enum BootSecurityPolicy {
    /// Historical developer escape hatch. Kept so existing launchd plists and
    /// scripts do not break during the warning-only rollout.
    public static let overrideEnvVar = "DARKBLOOM_ALLOW_INSECURE_BOOT"

    /// The minimum supported macOS major version. macOS 26 (Tahoe) is the floor:
    /// it is what makes `system_profiler SPiBridgeDataType` a reliable, sudo-free
    /// Secure Boot signal, and it is the only OS the provider is validated on.
    public static let minimumMacOSMajorVersion = 26

    /// macOS version posture: Tahoe or newer is the supported serving platform.
    /// During rollout, older versions warn locally and report telemetry; runtime
    /// readiness still handles Metal/MLX incompatibility.
    public static func macOSVerdict(_ majorVersion: Int) -> BootSecurityVerdict {
        majorVersion >= minimumMacOSMajorVersion ? .pass : .warn
    }

    /// One-line, human-readable summary of the macOS version state, shared by
    /// the doctor check detail and the start-preflight message.
    public static func macOSSummary(majorVersion: Int) -> String {
        if majorVersion >= minimumMacOSMajorVersion {
            return "macOS \(majorVersion) — meets the macOS \(minimumMacOSMajorVersion) (Tahoe) minimum"
        }
        return "macOS \(majorVersion) — below the supported macOS \(minimumMacOSMajorVersion) "
            + "(Tahoe); update for full support"
    }

    /// SIP posture: fully enabled passes; everything else warns locally. The
    /// coordinator's MDM hardware-trust path remains the hard enforcement layer.
    public static func sipVerdict(_ status: SIPStatus) -> BootSecurityVerdict {
        switch status {
        case .enabled:
            return .pass
        case .disabled, .enabledWithCustomConfiguration, .unavailable, .unrecognized:
            return .warn
        }
    }

    /// Secure Boot posture: provable Full Security (`ibridge_secure_boot == "Full
    /// Security"`, Apple Silicon or Intel T2) passes; a confidently-reported
    /// downgrade (Reduced/Medium/Permissive/No Security) or an undeterminable
    /// posture warns locally. MDM enforces Full Security for hardware trust.
    ///
    /// `pass` and `attestsSecureBoot` derive from the SAME `SecureBootStatus`, so
    /// the local verdict and the attested `secure_boot_enabled` never disagree.
    public static func secureBootVerdict(_ status: SecureBootStatus) -> BootSecurityVerdict {
        switch status {
        case .fullSecurity:
            return .pass
        case .reduced, .permissiveOrDisabled, .unavailable:
            return .warn
        }
    }

    // MARK: - Combined preflight decision

    /// Outcome of evaluating boot posture for the `start` preflight: the exact
    /// lines to print, plus legacy block fields kept stable for callers/tests.
    public struct PreflightDecision: Sendable, Equatable {
        /// Currently always false for boot posture: this rollout is non-blocking.
        public let shouldBlock: Bool
        /// Ordered lines to print (warnings + the enable guide). Empty when all
        /// protections pass.
        public let messageLines: [String]
        /// Currently always false; retained for compatibility with the previous
        /// previous blocking policy.
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
    /// - This rollout is intentionally non-blocking: failures/warnings are
    ///   surfaced locally and emitted through telemetry, while the coordinator's
    ///   MDM trust checks remain the hard enforcement layer.
    public static func preflightDecision(
        macOSMajorVersion: Int,
        sip: SIPStatus,
        secureBoot: SecureBootStatus,
        allowInsecureOverride _: Bool
    ) -> PreflightDecision {
        let macOSV = macOSVerdict(macOSMajorVersion)
        let sipV = sipVerdict(sip)
        let secureBootV = secureBootVerdict(secureBoot)
        guard macOSV != .pass || sipV != .pass || secureBootV != .pass else {
            return .ok
        }

        var lines: [String] = []
        lines.append(
            "WARNING: macOS boot security is not fully verified. Continuing while the coordinator enforces hardware trust."
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

        return PreflightDecision(shouldBlock: false, messageLines: lines, overrodeBlock: false)
    }
}
