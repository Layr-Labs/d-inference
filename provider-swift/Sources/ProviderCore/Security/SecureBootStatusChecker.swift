import Foundation

// MARK: - Secure Boot Checker

/// Reads the live Secure Boot posture, sudo-free, from
/// `system_profiler SPiBridgeDataType`.
///
/// A populated `SPiBridgeDataType` array carries `ibridge_secure_boot`, the
/// authoritative Secure Boot level (Full / Reduced-Medium / Permissive-No
/// Security). On the provider's minimum supported OS — macOS 26 (Tahoe) — this
/// data type is reliably populated on BOTH Apple Silicon (verified on M4 Max /
/// Mac16,5 / arm64) AND Intel T2, so it is the single source of truth. When the
/// array is empty/absent (anomalous on Tahoe) or `system_profiler` fails, the
/// posture is `.unavailable` — a WARN, never a false lockout.
///
/// The probe runs through the injectable `SecurityCommandRunner`, so the whole
/// detection path is unit-testable without depending on the host's boot policy.
public struct SecureBootStatusChecker: Sendable {
    private let runner: SecurityCommandRunner

    public init(runner: SecurityCommandRunner = .live) {
        self.runner = runner
    }

    public func status() -> SecureBootStatus {
        spiBridgeStatus() ?? .unavailable(
            reason: "system_profiler SPiBridgeDataType reported no ibridge_secure_boot level"
        )
    }

    /// True only when the machine *provably* reports Full Security — i.e.
    /// `ibridge_secure_boot == "Full Security"` from `SPiBridgeDataType`.
    public func isFullSecurity() -> Bool {
        status().isFullSecurity
    }

    // MARK: - system_profiler SPiBridgeDataType

    /// The authoritative `ibridge_secure_boot` level from `SPiBridgeDataType`,
    /// or `nil` when the array is empty/unavailable or the command fails, so the
    /// caller maps that to `.unavailable`.
    private func spiBridgeStatus() -> SecureBootStatus? {
        guard let result = try? runner.run(
            "/usr/sbin/system_profiler", ["-json", "SPiBridgeDataType"]
        ) else {
            return nil
        }
        return SecureBootStatusParser.spiBridgeStatus(result)
    }
}

// MARK: - Combined Snapshot

/// A single read of the boot-security state the provider gates on: the macOS
/// version, System Integrity Protection, and Secure Boot. Used by both the
/// `start` preflight and `doctor` so they evaluate the same captured state.
public struct BootSecuritySnapshot: Sendable, Equatable {
    public let macOSMajorVersion: Int
    public let sip: SIPStatus
    public let secureBoot: SecureBootStatus

    /// `macOSMajorVersion` defaults to the supported floor so suites exercising
    /// only the SIP / Secure Boot axes don't have to restate a passing OS; the
    /// macOS gate is exercised by passing an explicit version. `live(_:)` always
    /// reads the real OS version.
    public init(
        macOSMajorVersion: Int = BootSecurityPolicy.minimumMacOSMajorVersion,
        sip: SIPStatus,
        secureBoot: SecureBootStatus
    ) {
        self.macOSMajorVersion = macOSMajorVersion
        self.sip = sip
        self.secureBoot = secureBoot
    }

    /// Capture the live state. Both checkers share one injected runner and the
    /// OS major version is injectable, so the whole snapshot can be exercised
    /// deterministically in tests.
    public static func live(
        runner: SecurityCommandRunner = .live,
        macOSMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) -> BootSecuritySnapshot {
        BootSecuritySnapshot(
            macOSMajorVersion: macOSMajorVersion,
            sip: SIPStatusChecker(runner: runner).status(),
            secureBoot: SecureBootStatusChecker(runner: runner).status()
        )
    }
}
