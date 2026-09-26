import Foundation
import ProviderAppAttest

/// Gathers the process-level `ready` diagnostics. Boot-security probes spawn
/// `csrutil`/`diskutil`, so they run at most once per process; the rest is
/// cheap and read fresh on every `ready`.
public final class AppAttestProcessProbe: @unchecked Sendable {
    public struct BootSecurity: Sendable, Equatable {
        public var sipEnabled: Bool?
        public var authenticatedRoot: Bool?

        public init(sipEnabled: Bool?, authenticatedRoot: Bool?) {
            self.sipEnabled = sipEnabled
            self.authenticatedRoot = authenticatedRoot
        }

        /// SIP true only when fully enabled; nil when csrutil failed or its
        /// output was not recognized. Custom Configuration counts as false.
        public static func sip(_ status: SIPStatus) -> Bool? {
            switch status {
            case .enabled: return true
            case .enabledWithCustomConfiguration, .disabled: return false
            case .unavailable, .unrecognized: return nil
            }
        }
    }

    private let lock = NSLock()
    private var bootSecurity: BootSecurity?
    private let probeBootSecurity: @Sendable () -> BootSecurity
    private let consoleUser: @Sendable () -> String?
    private let preflight: @Sendable () -> AppAttestPreflight
    private let pushHistory: APNsPushHistoryStore
    private let deviceTokenPresent: @Sendable () -> Bool
    private let startContext: @Sendable () -> ProviderProcessRun.StartContext?
    private let now: @Sendable () -> Date

    public init(pushHistory: APNsPushHistoryStore,
                probeBootSecurity: @escaping @Sendable () -> BootSecurity = {
                    // At most three commands, one second each. A timeout
                    // produces unknown fields and never blocks authorization.
                    let runner = SecurityCommandRunner.bounded(timeout: 1)
                    return BootSecurity(sipEnabled: BootSecurity.sip(SIPStatusChecker(runner: runner).status()),
                                        authenticatedRoot: authenticatedRootStatus(runner: runner))
                },
                consoleUser: @escaping @Sendable () -> String? = { AttestationReadiness.currentConsoleUser() },
                preflight: @escaping @Sendable () -> AppAttestPreflight = { AppAttestPreflight.current() },
                deviceTokenPresent: @escaping @Sendable () -> Bool = { APNsBridge.shared.currentDeviceToken() != nil },
                startContext: @escaping @Sendable () -> ProviderProcessRun.StartContext? = { ProviderProcessRun.current },
                now: @escaping @Sendable () -> Date = Date.init) {
        self.pushHistory = pushHistory
        self.probeBootSecurity = probeBootSecurity
        self.consoleUser = consoleUser
        self.preflight = preflight
        self.deviceTokenPresent = deviceTokenPresent
        self.startContext = startContext
        self.now = now
    }

    public func diagnostics() -> AppAttestProcessDiagnostics {
        let boot = cachedBootSecurity()
        let start = startContext()
        return AppAttestProcessDiagnostics(
            processStartedAt: start?.processStartedAt,
            previousExit: start?.previousExit,
            startReason: start?.startReason,
            consoleUserActive: AttestationReadiness.isRealConsoleUser(consoleUser()),
            sipEnabled: boot.sipEnabled,
            authenticatedRoot: boot.authenticatedRoot,
            preflight: preflight(),
            pushHistory: pushHistory.load().summary(deviceTokenPresent: deviceTokenPresent(), now: now()))
    }

    private func cachedBootSecurity() -> BootSecurity {
        if let cached = lock.withLock({ bootSecurity }) { return cached }
        let probed = probeBootSecurity()
        return lock.withLock {
            if let raced = bootSecurity { return raced }
            bootSecurity = probed
            return probed
        }
    }
}
