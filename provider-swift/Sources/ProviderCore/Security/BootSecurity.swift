import Foundation

public enum BootSecurityVerdict: Sendable, Equatable {
    case pass
    case warn
}

public struct BootSecurityIssue: Sendable, Equatable {
    public let name: String
    public let detail: String
    public let fix: String
}

/// Local, warning-only posture. Secure Boot is intentionally absent because
/// macOS exposes no stable unprivileged local check for it.
public struct BootSecuritySnapshot: Sendable, Equatable {
    public static let recommendedMacOSMajorVersion = 26

    public let macOSMajorVersion: Int
    public let sip: SIPStatus

    public init(macOSMajorVersion: Int, sip: SIPStatus) {
        self.macOSMajorVersion = macOSMajorVersion
        self.sip = sip
    }

    public static func live(
        runner: SecurityCommandRunner = .live,
        macOSMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) -> BootSecuritySnapshot {
        BootSecuritySnapshot(
            macOSMajorVersion: macOSMajorVersion,
            sip: SIPStatusChecker(runner: runner).status()
        )
    }

    public var macOSVerdict: BootSecurityVerdict {
        macOSMajorVersion >= Self.recommendedMacOSMajorVersion ? .pass : .warn
    }

    public var sipVerdict: BootSecurityVerdict {
        sip.isFullyEnabled ? .pass : .warn
    }

    public var macOSSummary: String {
        let target = "macOS \(Self.recommendedMacOSMajorVersion) (Tahoe)"
        return macOSVerdict == .pass
            ? "macOS \(macOSMajorVersion) meets the recommended \(target) posture"
            : "macOS \(macOSMajorVersion) is below the recommended \(target) posture"
    }

    public var issues: [BootSecurityIssue] {
        var result: [BootSecurityIssue] = []
        if macOSVerdict == .warn {
            result.append(BootSecurityIssue(
                name: "macOS",
                detail: macOSSummary,
                fix: "Update in System Settings > General > Software Update."
            ))
        }
        if sipVerdict == .warn {
            let fix: String
            switch sip {
            case .disabled, .enabledWithCustomConfiguration:
                fix = "In recoveryOS, run `csrutil enable`, then restart."
            default:
                fix = "Run `csrutil status`; if it still cannot report SIP, run `darkbloom doctor`."
            }
            result.append(BootSecurityIssue(
                name: "System Integrity Protection (SIP)",
                detail: sip.summary,
                fix: fix
            ))
        }
        return result
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
                ? "" : "; disabled: \(disabledProtections.joined(separator: ", "))"
            return "enabled (Custom Configuration), not fully enabled\(disabled)"
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
