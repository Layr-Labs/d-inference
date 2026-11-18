import Foundation

public enum BootSecurityVerdict: Sendable, Equatable {
    case pass
    case warn
    /// Darkbloom serving stays off until this is fixed.
    case fail
}

public struct BootSecurityIssue: Sendable, Equatable {
    public let name: String
    public let detail: String
    public let fix: String
}

/// SIP is at Apple's default configuration. The kernel's value decides; only
/// when it cannot be read does `csrutil status` decide, and then only a plain
/// "enabled." counts.
public func sipAtDefaultConfiguration(_ configuration: SIPConfiguration?, status: SIPStatus) -> Bool {
    configuration?.isDefault ?? status.isFullyEnabled
}

/// Local boot-security posture. Darkbloom serving needs SIP at Apple's default
/// configuration (`sipAtDefault`) and a Secure Boot policy that is not
/// Reduced or Permissive (`servingRefusals`); an older macOS and an unreadable
/// Secure Boot report are advisory. Only me treats every issue as advisory.
public struct BootSecuritySnapshot: Sendable, Equatable {
    public static let recommendedMacOSMajorVersion = 26

    public let macOSMajorVersion: Int
    public let sip: SIPStatus
    /// The kernel's value; nil when it could not be read.
    public let sipConfiguration: SIPConfiguration?
    public let secureBoot: SecureBootPolicy

    public init(
        macOSMajorVersion: Int,
        sip: SIPStatus,
        sipConfiguration: SIPConfiguration? = nil,
        secureBoot: SecureBootPolicy = .unknown
    ) {
        self.macOSMajorVersion = macOSMajorVersion
        self.sip = sip
        self.sipConfiguration = sipConfiguration
        self.secureBoot = secureBoot
    }

    public static func live(
        runner: SecurityCommandRunner = .live,
        macOSMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) -> BootSecuritySnapshot {
        BootSecuritySnapshot(
            macOSMajorVersion: macOSMajorVersion,
            sip: SIPStatusChecker(runner: runner).status(),
            sipConfiguration: SIPConfigurationReader.current(),
            secureBoot: SecureBootPolicy.current()
        )
    }

    public var sipAtDefault: Bool {
        sipAtDefaultConfiguration(sipConfiguration, status: sip)
    }

    public var macOSVerdict: BootSecurityVerdict {
        macOSMajorVersion >= Self.recommendedMacOSMajorVersion ? .pass : .warn
    }

    public var sipVerdict: BootSecurityVerdict {
        sipAtDefault ? .pass : .fail
    }

    public var secureBootVerdict: BootSecurityVerdict {
        switch secureBoot {
        case .full: return .pass
        case .unknown: return .warn
        case .reduced, .permissive: return .fail
        }
    }

    public var macOSSummary: String {
        let target = "macOS \(Self.recommendedMacOSMajorVersion) (Tahoe)"
        return macOSVerdict == .pass
            ? "macOS \(macOSMajorVersion) meets the recommended \(target) posture"
            : "macOS \(macOSMajorVersion) is below the recommended \(target) posture"
    }

    /// Names every protection SIP has off: from the kernel's value when it was
    /// read, otherwise from `csrutil status`.
    public var sipSummary: String {
        guard let sipConfiguration else { return sip.summary }
        guard !sipConfiguration.isDefault else { return "enabled (default configuration)" }
        return "not at the default configuration (\(sipConfiguration.hexString)); off: "
            + sipConfiguration.relaxedProtections.joined(separator: ", ")
    }

    public var secureBootSummary: String {
        switch secureBoot {
        case .full: return "Full Security"
        case .reduced, .permissive: return "\(secureBoot.summary); Darkbloom serves only in Full Security"
        case .unknown: return "could not be read (`system_profiler SPiBridgeDataType`)"
        }
    }

    /// Why Darkbloom must not serve from this Mac; empty when it may.
    public var servingRefusals: [BootSecurityIssue] {
        var result: [BootSecurityIssue] = []
        if !sipAtDefault {
            result.append(BootSecurityIssue(
                name: "System Integrity Protection (SIP)",
                detail: sipSummary,
                fix: sipFix
            ))
        }
        if secureBoot.isDowngraded {
            result.append(BootSecurityIssue(
                name: "Secure Boot",
                detail: secureBootSummary,
                fix: "In recoveryOS, open Startup Security Utility, choose Full Security, then restart."
            ))
        }
        return result
    }

    /// Serving refusals first, then the advisory macOS version.
    public var issues: [BootSecurityIssue] {
        var result = servingRefusals
        if macOSVerdict == .warn {
            result.append(BootSecurityIssue(
                name: "macOS",
                detail: macOSSummary,
                fix: "Update in System Settings > General > Software Update."
            ))
        }
        return result
    }

    private var sipFix: String {
        guard let sipConfiguration else {
            switch sip {
            case .unavailable, .unrecognized:
                return "Run `csrutil status`; if it still cannot report SIP, "
                    + "run `\(BuildEnvironment.current.cliName) doctor`."
            case .enabled, .enabledWithCustomConfiguration, .disabled:
                return Self.recoveryOSFix("`csrutil enable`")
            }
        }
        return Self.recoveryOSFix(sipConfiguration.relaxesAuthenticatedRoot
            ? "`csrutil enable` and `csrutil authenticated-root enable`" : "`csrutil enable`")
    }

    private static func recoveryOSFix(_ commands: String) -> String {
        "In recoveryOS, run \(commands), then restart."
    }
}

extension SIPStatus {
    public var summary: String {
        switch self {
        case .enabled:
            return "enabled (full protection)"
        case .disabled:
            return "disabled"
        case .enabledWithCustomConfiguration(let disabledProtections):
            let disabled = disabledProtections.isEmpty
                ? "" : "; off: \(disabledProtections.joined(separator: ", "))"
            return "custom configuration, not the default\(disabled)"
        case .unavailable(let reason):
            return "could not determine (\(reason))"
        case .unrecognized:
            return "could not interpret csrutil output"
        }
    }

    public var telemetryValue: String {
        switch self {
        case .enabled: return "enabled"
        case .disabled: return "disabled"
        case .enabledWithCustomConfiguration: return "custom_configuration"
        case .unavailable: return "unavailable"
        case .unrecognized: return "unrecognized"
        }
    }
}
