import Foundation
import ProviderAppAttest

/// Answers "is the coordinator routing work to this provider, and if not,
/// why?" from the daemon state file. A connected provider with a loaded model
/// can still receive nothing when the coordinator has not authorized the
/// connection; without this verdict it looks healthy in `status`.
///
/// Diagnostics only: the coordinator owns routing and authorization.
public enum ServingReadiness {
    public enum Verdict: Equatable, Sendable {
        /// The coordinator currently authorizes this connection.
        case authorized(String)
        /// Too early to judge: just connected and no coordinator status yet.
        case pending(String)
        /// The coordinator cannot route work to this connection.
        case blocked(DiagnosticAdvice)
    }

    /// A coordinator sends its first status right after registration; none
    /// after this long means it never confirmed the connection.
    public static let statusGraceSeconds: Double = 90

    /// Nil when the daemon predates connection reporting (a reader cannot
    /// tell disconnected from connected), an add-on holds the connected Mac,
    /// or the coordinator sends no authorization verdict for a connection
    /// below hardware trust.
    public static func verdict(
        _ state: DaemonState, now: Double,
        macOSMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) -> Verdict? {
        guard let connection = state.coordinatorConnection else { return nil }
        let cli = BuildEnvironment.current.cliName
        // Many registrations in one run with short connections is a reconnect
        // loop: the coordinator closes each registration before routing it.
        let registrations = connection.connections > 1 ? "; registration \(connection.connections) since the provider started" : ""
        guard connection.connected else {
            return .blocked(DiagnosticAdvice(
                message: "not connected to the coordinator (disconnected \(age(since: connection.since, now: now)) ago\(registrations)); the provider reconnects on its own",
                fix: "check this Mac's network; if it stays disconnected, run `\(cli) restart`"))
        }
        // A hold keeps the connection but leaves routing on purpose; its own
        // status line explains the missing work, and authorization does not.
        if state.addonHold?.holds.isEmpty == false { return nil }
        guard let trust = state.trust else {
            if now - connection.since < statusGraceSeconds {
                return .pending("connected \(age(since: connection.since, now: now)) ago\(registrations); waiting for the coordinator's verdict")
            }
            return .blocked(DiagnosticAdvice(
                message: "connected for \(age(since: connection.since, now: now)), but the coordinator has not confirmed this connection",
                fix: "run `\(cli) restart`; if it persists, run `\(cli) doctor`"))
        }
        if trust.status == "untrusted" || trust.status == "offline" {
            return .blocked(TrustReasonCatalog.advice(
                level: trust.trustLevel, status: trust.status, reason: trust.reason,
                macOSMajorVersion: macOSMajorVersion))
        }
        guard let authorization = trust.authorization else {
            // A coordinator without App Attest serving sends no authorization
            // object. Hardware trust then serves; below it, routing depends on
            // that coordinator's trust floor, which the provider cannot see.
            return trust.trustLevel == "hardware" ? .authorized("hardware-trusted (legacy verification)") : nil
        }
        if authorization.hasCurrentAppAttestAuthorization(now: now), let expiresAt = authorization.expiresAt {
            return .authorized("App Attest authorized until \(clock(expiresAt)); renewed automatically")
        }
        if authorization.path == "legacy" {
            return .authorized("legacy (MDM) verification active")
        }
        if authorization.path == "app_attest", let expiresAt = authorization.expiresAt {
            return .blocked(DiagnosticAdvice(
                message: "App Attest authorization expired at \(clock(expiresAt)) and has not been renewed",
                fix: localCause(state.appAttest, macOSMajorVersion: macOSMajorVersion)?.fix
                    ?? "the coordinator retries within 10 minutes; if it persists, run `\(cli) restart`"))
        }
        return .blocked(blockedCause(
            reason: authorization.reason, appAttest: state.appAttest, macOSMajorVersion: macOSMajorVersion))
    }

    /// The cause of an unauthorized connection. A local App Attest observation
    /// is the most specific evidence, then the coordinator's reason.
    static func blockedCause(
        reason: String, appAttest: AppAttestLocalStatus?, macOSMajorVersion: Int
    ) -> DiagnosticAdvice {
        if let local = localCause(appAttest, macOSMajorVersion: macOSMajorVersion) { return local }
        let cli = BuildEnvironment.current.cliName
        let restart = "if it persists for 30 minutes, run `\(cli) restart`"
        switch reason {
        case "app_attest_keychain_error":
            return DiagnosticAdvice(
                message: "the coordinator is not routing work here: the login keychain refused this Mac's App Attest key record (it is usually locked)",
                fix: "log in at this Mac's console to unlock the login keychain; serving resumes within about 10 minutes")
        case "app_attest_busy", "app_attest_operation_timeout":
            return DiagnosticAdvice(
                message: "the coordinator is not routing work here: Apple's App Attest call on this Mac did not return in time",
                fix: "run `\(cli) restart` if it lasts more than 15 minutes (the provider also restarts itself when idle, at most once every 6 hours)")
        case "app_attest_unsupported":
            return unsupported(macOSMajorVersion: macOSMajorVersion)
        case "app_attest_identity_required":
            return DiagnosticAdvice(
                message: "the coordinator is not routing work here: this connection has no linked Darkbloom account (the device login was rejected or is missing)",
                fix: "run `\(cli) login`, then `\(cli) restart`")
        case "app_attest_provider_upgrade_required":
            return DiagnosticAdvice(
                message: "the coordinator is not routing work here: this provider version is too old for App Attest",
                fix: "run `\(cli) update`")
        case "app_attest_timeout", "app_attest_send_failed":
            return DiagnosticAdvice(
                message: "the coordinator is not routing work here: its App Attest exchange with this Mac timed out",
                fix: "check this Mac's network and that it is not sleeping; the coordinator retries within 10 minutes; \(restart)")
        case "app_attest_apple_error", "app_attest_apple_unavailable", "app_attest_apple_invalid_key", "app_attest_key_unregistered":
            return DiagnosticAdvice(
                message: "the coordinator is not routing work here: Apple's App Attest service failed for this Mac (\(reason.dropFirst("app_attest_".count)))",
                fix: "the coordinator retries and replaces a dead key on its own; \(restart)")
        case "app_attest_qualification_required", "":
            return DiagnosticAdvice(
                message: "the coordinator is not routing work here: it has not qualified this connection for App Attest yet",
                fix: "wait up to 10 minutes; \(restart) and check `\(cli) doctor`")
        default:
            if reason.hasPrefix("app_attest_") {
                return DiagnosticAdvice(
                    message: "the coordinator is not routing work here: App Attest verification did not complete (\(reason.dropFirst("app_attest_".count)))",
                    fix: "the coordinator retries on its own; if it persists, run `\(cli) update` and then `\(cli) restart`")
            }
            return DiagnosticAdvice(message: "the coordinator is not routing work here: \(reason)", fix: nil)
        }
    }

    /// Local App Attest conditions that keep every exchange failing until
    /// the operator or a new process changes them.
    static func localCause(_ status: AppAttestLocalStatus?, macOSMajorVersion: Int) -> DiagnosticAdvice? {
        guard let status else { return nil }
        let cli = BuildEnvironment.current.cliName
        if let stalled = status.operationStalledSeconds {
            return DiagnosticAdvice(
                message: "the coordinator is not routing work here: an Apple App Attest call has not returned for \(formatDuration(TimeInterval(stalled))); App Attest answers busy until the provider process restarts",
                fix: "run `\(cli) restart` (the provider also restarts itself when idle, at most once every 6 hours)")
        }
        switch status.availabilityReason {
        case .osBelow27?:
            return unsupported(macOSMajorVersion: min(macOSMajorVersion, 26))
        case .isSupportedFalse?:
            return unsupported(macOSMajorVersion: max(macOSMajorVersion, 27))
        case let reason?:
            // `update` leaves a current version in place; this is the
            // reinstall doctor's `app signing` check gives.
            return DiagnosticAdvice(
                message: "the coordinator is not routing work here: this provider installation cannot use App Attest (\(reason.rawValue))",
                fix: "reinstall the signed release: `curl -fsSL \(BuildEnvironment.current.coordinatorHTTPURL)/install.sh | bash`, then `\(cli) restart`")
        case nil:
            return nil
        }
    }

    private static func unsupported(macOSMajorVersion: Int) -> DiagnosticAdvice {
        let cli = BuildEnvironment.current.cliName
        if !ProviderOnboardingPolicy.usesAppAttest(macOSMajorVersion: macOSMajorVersion) {
            return DiagnosticAdvice(
                message: "the coordinator is not routing work here: App Attest needs macOS 27 or later, and on this macOS only Macs already in the legacy MDM cohort can serve",
                fix: "upgrade to macOS 27 or later, then run `\(cli) restart`")
        }
        return DiagnosticAdvice(
            message: "the coordinator is not routing work here: macOS reports App Attest as unavailable to this provider process, usually because it was not started in a logged-in GUI session",
            fix: "log in at this Mac's console (not only over SSH) and run `\(cli) restart` from that session")
    }

    private static func age(since: Double, now: Double) -> String {
        formatDuration(max(0, now - since))
    }

    private static func clock(_ epoch: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm:ss'Z'"
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
    }
}
