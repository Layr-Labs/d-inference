import Foundation

public enum BootSecurityVerdict: Sendable, Equatable {
    case pass
    case warn
    /// Darkbloom serving stays off until this is fixed.
    case fail
}

public struct BootSecurityIssue: Sendable, Equatable {
    /// What the issue is about, categorical (a running service reports the
    /// refusals it holds for, `DaemonState.bootSecurityHold`).
    public enum Kind: String, Sendable, Equatable {
        case sip
        case secureBoot = "secure_boot"
        case processSandbox = "process_sandbox"
        case macOS = "macos"

        public var displayName: String {
            switch self {
            case .sip: return "System Integrity Protection (SIP)"
            case .secureBoot: return "Secure Boot"
            case .processSandbox: return "Process sandbox"
            case .macOS: return "macOS"
            }
        }
    }

    public let kind: Kind
    public let detail: String
    public let fix: String

    public var name: String { kind.displayName }

    public init(kind: Kind, detail: String, fix: String) {
        self.kind = kind
        self.detail = detail
        self.fix = fix
    }
}

/// SIP is at Apple's default configuration. The kernel's value decides; only
/// when it cannot be read does `csrutil status` decide, and then only a plain
/// "enabled." counts.
public func sipAtDefaultConfiguration(_ configuration: SIPConfiguration?, status: SIPStatus) -> Bool {
    configuration?.isDefault ?? status.isFullyEnabled
}

/// Local boot-security posture. Darkbloom serving needs SIP at Apple's default
/// configuration (`sipAtDefault`), a Secure Boot policy that is not Reduced or
/// Permissive, and a process outside any sandbox Darkbloom didn't set up
/// (`servingRefusals`); an older macOS, an unreadable Secure Boot report and an
/// unanswered sandbox check are advisory. Only me treats every issue as advisory.
public struct BootSecuritySnapshot: Sendable, Equatable {
    public static let recommendedMacOSMajorVersion = 26

    public let macOSMajorVersion: Int
    public let sip: SIPStatus
    /// The kernel's value; nil when it could not be read.
    public let sipConfiguration: SIPConfiguration?
    public let secureBoot: SecureBootPolicy
    public let processSandbox: ProcessSandbox

    public init(
        macOSMajorVersion: Int,
        sip: SIPStatus,
        sipConfiguration: SIPConfiguration? = nil,
        secureBoot: SecureBootPolicy = .unknown,
        processSandbox: ProcessSandbox = .notSandboxed
    ) {
        self.macOSMajorVersion = macOSMajorVersion
        self.sip = sip
        self.sipConfiguration = sipConfiguration
        self.secureBoot = secureBoot
        self.processSandbox = processSandbox
    }

    public static func live(
        runner: SecurityCommandRunner = .live,
        macOSMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) -> BootSecuritySnapshot {
        BootSecuritySnapshot(
            macOSMajorVersion: macOSMajorVersion,
            sip: SIPStatusChecker(runner: runner).status(),
            sipConfiguration: SIPConfigurationReader.current(),
            secureBoot: SecureBootPolicy.current(),
            processSandbox: ProcessSandbox.current()
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

    public var processSandboxVerdict: BootSecurityVerdict {
        switch processSandbox {
        case .notSandboxed: return .pass
        case .unknown: return .warn
        case .sandboxed: return .fail
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

    public var processSandboxSummary: String {
        switch processSandbox {
        case .notSandboxed: return "not sandboxed"
        case .sandboxed: return "running inside a sandbox Darkbloom didn't set up, where it can't verify boot security"
        case .unknown: return "could not be checked (`sandbox_check`)"
        }
    }

    /// Why Darkbloom must not serve from this Mac; empty when it may.
    public var servingRefusals: [BootSecurityIssue] {
        var result: [BootSecurityIssue] = []
        if !sipAtDefault {
            result.append(BootSecurityIssue(
                kind: .sip,
                detail: sipSummary,
                fix: sipFix
            ))
        }
        if secureBoot.isDowngraded {
            result.append(BootSecurityIssue(
                kind: .secureBoot,
                detail: secureBootSummary,
                fix: "In recoveryOS, open Startup Security Utility, choose Full Security, then restart."
            ))
        }
        if processSandbox == .sandboxed {
            let cli = BuildEnvironment.current.cliName
            result.append(BootSecurityIssue(
                kind: .processSandbox,
                detail: processSandboxSummary,
                fix: "Start Darkbloom from a standard installation and session (`\(cli) start`), not inside "
                    + "that sandbox. Only me (`\(cli) start --local`) serves your own requests meanwhile."
            ))
        }
        return result
    }

    /// Serving refusals first, then the advisory ones: an unanswered sandbox
    /// check and the macOS version.
    public var issues: [BootSecurityIssue] {
        var result = servingRefusals
        if processSandbox == .unknown {
            result.append(BootSecurityIssue(
                kind: .processSandbox,
                detail: processSandboxSummary,
                fix: "Run `\(BuildEnvironment.current.cliName) doctor` again; if it still can't be checked, update macOS."
            ))
        }
        if macOSVerdict == .warn {
            result.append(BootSecurityIssue(
                kind: .macOS,
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
