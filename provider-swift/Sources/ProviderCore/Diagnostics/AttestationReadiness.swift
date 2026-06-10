import Foundation

#if canImport(SystemConfiguration)
import SystemConfiguration
#endif

/// "Will this box be able to do APNs code-identity attestation?"
///
/// v0.6.0 ships APNs code-identity attestation. A provider can only obtain an
/// APNs device token (and therefore answer code-identity challenges) when the
/// process runs in a logged-in macOS GUI / Aqua session — AppKit's
/// `registerForRemoteNotifications()` is not daemon-safe and silently no-ops
/// without a console session. Once the coordinator starts enforcing
/// (`APNS_ENFORCE_AFTER`), un-attested providers are derouted.
///
/// The fleet-wide view already exists (`/v1/stats code_attested_providers`);
/// this is the per-box complement an operator runs locally before enforcement
/// bites, so they can fix a misconfigured machine in advance.
///
/// Design: the verdict logic (`evaluate`) is a pure function over the three raw
/// inputs so it is unit-testable without touching the real system. The IO that
/// gathers those values from the live machine lives in `gather()` and is kept
/// deliberately thin.
public enum AttestationReadiness {
    /// Raw, IO-gathered inputs the verdict is computed from. Pure value type so
    /// tests can construct any state directly.
    public struct Inputs: Sendable, Equatable {
        /// The console (Aqua-session) user from `SCDynamicStoreCopyConsoleUser`,
        /// or nil when no one is logged in at the console. "loginwindow" / "root"
        /// / "" are treated as "no real console session".
        public let consoleUser: String?
        /// `autoLoginUser` from `/Library/Preferences/com.apple.loginwindow.plist`,
        /// or nil when automatic login is not configured.
        public let autoLoginUser: String?
        /// `com.apple.autologout.AutoLogOutDelay` (seconds) from global prefs.
        /// 0 or nil means "log out after inactivity" is disabled.
        public let autoLogoutDelaySeconds: Int?

        public init(consoleUser: String?, autoLoginUser: String?, autoLogoutDelaySeconds: Int?) {
            self.consoleUser = consoleUser
            self.autoLoginUser = autoLoginUser
            self.autoLogoutDelaySeconds = autoLogoutDelaySeconds
        }
    }

    /// True when `user` is a real, logged-in console user (not nil, empty,
    /// the login window placeholder, or a non-Aqua system account).
    static func isRealConsoleUser(_ user: String?) -> Bool {
        guard let user = user?.trimmingCharacters(in: .whitespacesAndNewlines), !user.isEmpty else {
            return false
        }
        // SCDynamicStoreCopyConsoleUser returns "loginwindow" (and historically
        // can return "root") while sitting at the login window — i.e. no Aqua
        // session a GUI app could attach to.
        let placeholders: Set<String> = ["loginwindow", "root", "_mbsetupuser"]
        return !placeholders.contains(user.lowercased())
    }

    /// Pure verdict logic: turns the three raw inputs into operator-facing
    /// diagnostics. Same input → same output, no IO.
    ///
    /// Ordered most-to-least critical:
    ///  1. console session present (the headline — no session, no APNs token)
    ///  2. automatic login (so the box self-recovers a session after reboot)
    ///  3. auto-logout-after-idle (the silent killer of the GUI agent)
    ///  4. sleep prevention (informational; the provider self-caffeinates)
    public static func evaluate(
        consoleUser: String?,
        autoLoginUser: String?,
        autoLogoutDelaySeconds: Int?,
        sleepPrevented: Bool? = nil
    ) -> [Diagnostic] {
        var out: [Diagnostic] = []

        // ---- 1. Console GUI session present (critical) ----
        let hasSession = isRealConsoleUser(consoleUser)
        if hasSession {
            out.append(Diagnostic(
                section: .attestationReadiness, name: "console session",
                level: .pass,
                message: "a user is logged in at the console (\(consoleUser ?? "?")) — this box can obtain an APNs token and attest its code identity.",
                fix: nil))
        } else {
            out.append(Diagnostic(
                section: .attestationReadiness, name: "console session",
                level: .fail,
                message: "no user is logged in at the console (Aqua session) — without a GUI session the provider can't register for remote notifications, so it can't obtain an APNs token or attest. Once the coordinator enforces APNs code-identity, this box will be derouted.",
                fix: "log in at the physical login window (or via screen sharing) so a real Aqua session exists, then keep the provider running inside that session. Enable automatic login so the session survives reboots."))
        }

        // ---- 2. Automatic login (so a session exists after reboot) ----
        if let autoLoginUser, !autoLoginUser.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append(Diagnostic(
                section: .attestationReadiness, name: "automatic login",
                level: .pass,
                message: "automatic login is enabled for \(autoLoginUser) — after a reboot the box logs back into a console session on its own.",
                fix: nil))
        } else {
            out.append(Diagnostic(
                section: .attestationReadiness, name: "automatic login",
                level: .warn,
                message: "automatic login is not configured — after a reboot the box sits at the login window with no Aqua session, so it can't obtain an APNs token or attest until someone logs in.",
                fix: "System Settings → Users & Groups → Automatically log in as → pick this provider's user, so the session (and APNs registration) self-recovers after a reboot."))
        }

        // ---- 3. Auto-logout-after-idle (DANGER) ----
        // Screen LOCK is fine — only LOGOUT ends the Aqua session and kills the
        // gui-domain LaunchAgent (and its self-`caffeinate`), so the provider
        // dies and can no longer attest.
        if let delay = autoLogoutDelaySeconds, delay > 0 {
            let minutes = max(1, delay / 60)
            out.append(Diagnostic(
                section: .attestationReadiness, name: "auto-logout on idle",
                level: .fail,
                message: "\"Log out after \(minutes) min of inactivity\" is enabled (AutoLogOutDelay=\(delay)s) — when it fires it ends the Aqua session, killing the provider's GUI LaunchAgent (and its caffeinate). The box then goes offline and can't attest.",
                fix: "disable auto-logout: System Settings → Privacy & Security → Advanced → turn OFF \"Log out automatically after N minutes of inactivity\" (or run `sudo defaults delete /Library/Preferences/.GlobalPreferences com.apple.autologout.AutoLogOutDelay`). Screen lock is fine — only logout is the problem."))
        } else {
            out.append(Diagnostic(
                section: .attestationReadiness, name: "auto-logout on idle",
                level: .pass,
                message: "auto-logout after inactivity is disabled — the console session won't be ended out from under the provider.",
                fix: nil))
        }

        // ---- 4. Sleep prevention (informational / low priority) ----
        // The provider self-caffeinates while serving, so this is informational
        // only. Surface it when we have a reading; otherwise leave it UNKNOWN.
        switch sleepPrevented {
        case .some(true):
            out.append(Diagnostic(
                section: .attestationReadiness, name: "sleep prevention",
                level: .pass,
                message: "system sleep is currently prevented (the provider self-caffeinates while serving).",
                fix: nil))
        case .some(false):
            out.append(Diagnostic(
                section: .attestationReadiness, name: "sleep prevention",
                level: .warn,
                message: "system sleep is not currently prevented. The provider caffeinates itself while a request is in flight, so this is informational; deep idle sleep can still delay reconnect/attestation.",
                fix: "optional: `sudo pmset -a sleep 0` (or `disablesleep 1`) on an always-on box to avoid idle-sleep reconnect lag."))
        case .none:
            out.append(Diagnostic(
                section: .attestationReadiness, name: "sleep prevention",
                level: .warn,
                message: "couldn't read the system sleep state (informational only — the provider self-caffeinates while serving).",
                fix: nil))
        }

        return out
    }

    /// Convenience: evaluate directly from gathered `Inputs`.
    public static func evaluate(_ inputs: Inputs, sleepPrevented: Bool? = nil) -> [Diagnostic] {
        evaluate(
            consoleUser: inputs.consoleUser,
            autoLoginUser: inputs.autoLoginUser,
            autoLogoutDelaySeconds: inputs.autoLogoutDelaySeconds,
            sleepPrevented: sleepPrevented)
    }

    // MARK: - IO (live machine probes)

    /// Reads the three raw signals from the live machine. macOS-only; on other
    /// platforms returns all-nil (the verdict then reports a FAIL/UNKNOWN, which
    /// is correct — a non-macOS box can't do APNs attestation anyway).
    public static func gather() -> Inputs {
        Inputs(
            consoleUser: currentConsoleUser(),
            autoLoginUser: configuredAutoLoginUser(),
            autoLogoutDelaySeconds: configuredAutoLogoutDelaySeconds())
    }

    /// The console (Aqua-session) user via `SCDynamicStoreCopyConsoleUser`.
    /// Returns nil when no one is logged in at the console.
    public static func currentConsoleUser() -> String? {
        #if canImport(SystemConfiguration)
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard let store = SCDynamicStoreCreate(nil, "darkbloom.doctor" as CFString, nil, nil) else {
            return nil
        }
        guard let name = SCDynamicStoreCopyConsoleUser(store, &uid, &gid) else {
            return nil
        }
        return name as String
        #else
        return nil
        #endif
    }

    /// `autoLoginUser` from `/Library/Preferences/com.apple.loginwindow.plist`.
    public static func configuredAutoLoginUser() -> String? {
        #if os(macOS)
        let path = "/Library/Preferences/com.apple.loginwindow.plist"
        guard let dict = NSDictionary(contentsOfFile: path) else { return nil }
        guard let user = dict["autoLoginUser"] as? String else { return nil }
        let trimmed = user.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
        #else
        return nil
        #endif
    }

    /// `com.apple.autologout.AutoLogOutDelay` (seconds) from the system global
    /// preferences. 0 / absent ⇒ auto-logout disabled (returns nil).
    public static func configuredAutoLogoutDelaySeconds() -> Int? {
        #if os(macOS)
        // The setting lives in the system-domain global prefs. The plist on
        // disk is `.GlobalPreferences.plist`; the CFPreferences domain is
        // `.GlobalPreferences` / `kCFPreferencesAnyApplication`.
        let candidates = [
            "/Library/Preferences/.GlobalPreferences.plist",
            "/Library/Preferences/com.apple.GlobalPreferences.plist",
        ]
        for path in candidates {
            guard let dict = NSDictionary(contentsOfFile: path) else { continue }
            if let raw = dict["com.apple.autologout.AutoLogOutDelay"] {
                if let n = (raw as? NSNumber)?.intValue { return n > 0 ? n : nil }
                if let s = raw as? String, let n = Int(s) { return n > 0 ? n : nil }
            }
        }
        return nil
        #else
        return nil
        #endif
    }
}
