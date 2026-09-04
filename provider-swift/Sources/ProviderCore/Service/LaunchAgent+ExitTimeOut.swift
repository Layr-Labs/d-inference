/// `ExitTimeOut` reconciliation for installs that never re-run `darkbloom
/// start`.
///
/// The plist is written by `installAndStart` only. The fleet takes new
/// builds through auto-update, whose restart is `launchctl kickstart -k`
/// against the LOADED job definition — launchd re-reads the plist at
/// bootstrap (login, reboot, `darkbloom start`), never on a kickstart — so an
/// auto-updated box keeps launchd's 20 s default until its next bootstrap
/// while the daemon believes it has the full drain bound. Two halves close
/// that gap: the daemon clamps its own shutdown drain to the loaded job's
/// effective budget (`loadedExitTimeOutSeconds`, from `launchctl print`), and
/// rewrites the on-disk plist so the next bootstrap carries the intended
/// value (`reconcileExitTimeOutOnDisk`).

import Foundation

extension LaunchAgent {

    /// The loaded provider job's effective `ExitTimeOut` in seconds — the
    /// SIGTERM→SIGKILL budget launchd will actually apply — or nil when no
    /// supported label is loaded or `launchctl print` did not report one.
    public static func loadedExitTimeOutSeconds() -> Int? {
        launchSnapshot()?.exitTimeoutSeconds
    }

    /// Rewrite the plist's `ExitTimeOut` (and nothing else) when the on-disk
    /// value differs from this binary's `exitTimeOutSeconds`. Returns true
    /// when the file was rewritten. Best-effort: an unreadable or foreign
    /// file is left alone.
    @discardableResult
    public static func reconcileExitTimeOutOnDisk(at plistURL: URL = plistPath()) -> Bool {
        guard let data = try? Data(contentsOf: plistURL),
              var plist = (try? PropertyListSerialization.propertyList(
                from: data, format: nil)) as? [String: Any]
        else { return false }
        guard updatingExitTimeOut(&plist) else { return false }
        guard let rewritten = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        else { return false }
        do {
            try rewritten.write(to: plistURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Pure half of `reconcileExitTimeOutOnDisk`: set `ExitTimeOut` to the
    /// current value, reporting whether the dictionary changed. Every other
    /// key (program arguments, environment, log paths) is untouched.
    static func updatingExitTimeOut(_ plist: inout [String: Any]) -> Bool {
        if let current = plist["ExitTimeOut"] as? Int, current == exitTimeOutSeconds {
            return false
        }
        plist["ExitTimeOut"] = exitTimeOutSeconds
        return true
    }
}
