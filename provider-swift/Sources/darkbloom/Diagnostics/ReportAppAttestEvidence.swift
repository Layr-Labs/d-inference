import Darwin
import Foundation
import ProviderAppAttest
import ProviderCore

/// App Attest evidence appended to the user-initiated `darkbloom report`:
/// the daemon's last local App Attest snapshot, the APNs push history
/// summary and closed-pattern devicecheckd log matches. All closed fields;
/// nothing here is sent without the operator running `darkbloom report`.
enum ReportAppAttestEvidence {
    struct Snapshot: Encodable {
        let source = "darkbloom.app_attest_state"
        let appAttest: AppAttestLocalStatus?
        let pushHistory: AppAttestPushHistory
    }

    /// snake_case throughout, matching the daemon state file and the wire.
    static func snapshotLine(state: DaemonState?, pushHistory: APNsPushHistory, now: Date) -> Data {
        let snapshot = Snapshot(appAttest: state?.appAttest,
                                pushHistory: pushHistory.summary(deviceTokenPresent: pushHistory.deviceTokenPresent, now: now))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard var data = try? encoder.encode(snapshot) else { return Data() }
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// Under `sudo darkbloom report`, read the invoking user's auth token and
    /// daemon files rather than root's. Only the system log needs elevation.
    /// Returns that user's home, or nil when not running under sudo.
    @discardableResult
    static func adoptInvokingUserFiles(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard getuid() == 0, let user = environment["SUDO_USER"], !user.isEmpty, user != "root",
              let entry = getpwnam(user), let dir = entry.pointee.pw_dir else { return nil }
        let home = URL(fileURLWithPath: String(cString: dir))
        let darkbloom = home.appendingPathComponent(".darkbloom")
        if environment["DARKBLOOM_AUTH_TOKEN_PATH"] == nil {
            setenv("DARKBLOOM_AUTH_TOKEN_PATH", darkbloom.appendingPathComponent("auth_token").path, 1)
        }
        if environment["DARKBLOOM_STATE_FILE"] == nil {
            setenv("DARKBLOOM_STATE_FILE", darkbloom.appendingPathComponent("daemon-state.json").path, 1)
        }
        return home
    }

    /// The provider config a report reads: an explicit `--config` wins; under
    /// sudo, the invoking user's config, so the report and that user's token
    /// go to their coordinator rather than root's default one.
    static func configPath(explicit: String?, invokingHome: URL?) -> String? {
        explicit ?? invokingHome.map { ConfigManager.defaultConfigPath(home: $0).path }
    }
}
