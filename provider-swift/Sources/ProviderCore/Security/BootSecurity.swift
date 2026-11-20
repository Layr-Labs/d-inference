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
        case authenticatedRoot = "authenticated_root"
        case macOS = "macos"

        public var displayName: String {
            switch self {
            case .sip: return "System Integrity Protection (SIP)"
            case .secureBoot: return "Secure Boot"
            case .processSandbox: return "Process sandbox"
            case .authenticatedRoot: return "Authenticated root"
            case .macOS: return "macOS"
            }
        }

        /// The remedy when only the kind is known (a running service's hold).
        public var fix: String {
            let cli = BuildEnvironment.current.cliName
            switch self {
            case .sip: return "In recoveryOS, run `csrutil enable`, then restart."
            case .secureBoot: return "In recoveryOS, open Startup Security Utility, choose Full Security, then restart."
            case .processSandbox:
                return "Start Darkbloom from a standard installation and session (`\(cli) start`), not inside "
                    + "that sandbox. Only me (`\(cli) start --local`) serves your own requests meanwhile."
            case .authenticatedRoot: return "In recoveryOS, run `csrutil authenticated-root enable`, then restart."
            case .macOS: return "Update in System Settings > General > Software Update."
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
/// Permissive, authenticated root not turned off, and a process outside any
/// sandbox Darkbloom didn't set up (`servingRefusals`); an older macOS, an
/// unreadable Secure Boot or authenticated root report and an unanswered sandbox
/// check are advisory. Only me treats every issue as advisory.
public struct BootSecuritySnapshot: Sendable, Equatable {
    public static let recommendedMacOSMajorVersion = 26

    public let macOSMajorVersion: Int
    public let sip: SIPStatus
    /// The kernel's value; nil when it could not be read.
    public let sipConfiguration: SIPConfiguration?
    public let secureBoot: SecureBootPolicy
    /// Why `secureBoot` is unknown, when its reading said; nil otherwise.
    public let secureBootReadFailure: SecureBootReadFailure?
    /// How many reads were attempted for `secureBoot`; 0 for a snapshot
    /// built without a reading.
    public let secureBootReadAttempts: Int
    public let processSandbox: ProcessSandbox
    /// The signed system volume check (`authenticatedRootPolicy`): false only when
    /// `csrutil` says it is disabled; nil when unread or not read.
    public let authenticatedRoot: Bool?

    /// Each authenticated-root command (`csrutil authenticated-root status`,
    /// `diskutil info /`) gets this long; a hung tool is killed and the reading is
    /// unread, which only warns.
    public static let commandTimeout: TimeInterval = 5
    /// `csrutil status` decides SIP only when the kernel value can't be read, and
    /// then a timeout refuses (SIP fails closed), so it gets a longer budget; it
    /// answers in about 10 ms on a default Mac. (`system_profiler` keeps its own
    /// bounds, `SecureBootPolicy.liveRunner`.)
    public static let sipCommandTimeout: TimeInterval = 30
    /// The authenticated-root readings' default runner.
    public static let liveRunner = SecurityCommandRunner.bounded(timeout: commandTimeout)

    public init(
        macOSMajorVersion: Int,
        sip: SIPStatus,
        sipConfiguration: SIPConfiguration? = nil,
        secureBoot: SecureBootPolicy = .unknown,
        secureBootReadFailure: SecureBootReadFailure? = nil,
        secureBootReadAttempts: Int = 0,
        processSandbox: ProcessSandbox = .notSandboxed,
        authenticatedRoot: Bool? = nil
    ) {
        self.macOSMajorVersion = macOSMajorVersion
        self.sip = sip
        self.sipConfiguration = sipConfiguration
        self.secureBoot = secureBoot
        self.secureBootReadFailure = secureBoot == .unknown ? secureBootReadFailure : nil
        self.secureBootReadAttempts = secureBootReadAttempts
        self.processSandbox = processSandbox
        self.authenticatedRoot = authenticatedRoot
    }

    /// This Mac's reading. `runner` stands in for every boot-settings command
    /// (`csrutil`, `diskutil`, `system_profiler`) and `kernelSIP` for the kernel's
    /// SIP value, for tests and the collector fixture; production passes neither,
    /// so each command keeps its own budget. `secureBoot` is a Secure Boot reading
    /// the caller already took (the service's, which reads again after a failure);
    /// without it this reads once.
    public static func live(
        runner: SecurityCommandRunner? = nil,
        macOSMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        kernelSIP: () -> SIPConfiguration? = { SIPConfigurationReader.current() },
        secureBoot: SecureBootReading? = nil
    ) -> BootSecuritySnapshot {
        let sip = SIPStatusChecker(runner: runner ?? .bounded(timeout: sipCommandTimeout)).status()
        let sipConfiguration = kernelSIP()
        let secureBoot = secureBoot ?? SecureBootPolicy.read(runner: runner ?? SecureBootPolicy.liveRunner())
        return BootSecuritySnapshot(
            macOSMajorVersion: macOSMajorVersion,
            sip: sip,
            sipConfiguration: sipConfiguration,
            secureBoot: secureBoot.policy,
            secureBootReadFailure: secureBoot.failure,
            secureBootReadAttempts: secureBoot.attempts,
            processSandbox: ProcessSandbox.current(),
            authenticatedRoot: authenticatedRootPolicy(runner: runner ?? liveRunner)
        )
    }

    /// This snapshot with a later Secure Boot reading in place of its own; the
    /// attempts add up.
    public func rereadingSecureBoot(_ reading: SecureBootReading) -> BootSecuritySnapshot {
        BootSecuritySnapshot(
            macOSMajorVersion: macOSMajorVersion,
            sip: sip,
            sipConfiguration: sipConfiguration,
            secureBoot: reading.policy,
            secureBootReadFailure: reading.failure,
            secureBootReadAttempts: secureBootReadAttempts + reading.attempts,
            processSandbox: processSandbox,
            authenticatedRoot: authenticatedRoot
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

    public var authenticatedRootVerdict: BootSecurityVerdict {
        switch authenticatedRoot {
        case true?: return .pass
        case false?: return .fail
        case nil: return .warn
        }
    }

    public var authenticatedRootSummary: String {
        switch authenticatedRoot {
        case true?: return "enabled"
        case false?: return "disabled; Darkbloom serves only with it enabled"
        case nil: return "could not be read (`csrutil authenticated-root status`)"
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
        case .unknown:
            guard let failure = secureBootReadFailure else { return "could not be read (`system_profiler SPiBridgeDataType`)" }
            let tries = secureBootReadAttempts > 1 ? ", \(secureBootReadAttempts) tries" : ""
            return "could not be read (`system_profiler SPiBridgeDataType`: \(failure.summary)\(tries))"
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
            result.append(BootSecurityIssue(kind: .secureBoot, detail: secureBootSummary, fix: BootSecurityIssue.Kind.secureBoot.fix))
        }
        if authenticatedRoot == false {
            result.append(BootSecurityIssue(kind: .authenticatedRoot, detail: authenticatedRootSummary,
                                            fix: BootSecurityIssue.Kind.authenticatedRoot.fix))
        }
        if processSandbox == .sandboxed {
            result.append(BootSecurityIssue(kind: .processSandbox, detail: processSandboxSummary,
                                            fix: BootSecurityIssue.Kind.processSandbox.fix))
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
            result.append(BootSecurityIssue(kind: .macOS, detail: macOSSummary, fix: BootSecurityIssue.Kind.macOS.fix))
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
