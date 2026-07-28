import Foundation

/// Dev-only "all security disabled" switch, mirrored by the coordinator's
/// `EIGENINFERENCE_DEV_INSECURE`. When `DARKBLOOM_DEV_INSECURE` is truthy the
/// provider:
///   - downgrades start-time preflight *security* throws (SIP off, debugger
///     attached) to warnings instead of refusing to start,
///   - skips the release security-hardening posture verification (it still
///     attempts the Secure Enclave self-sign and always keeps X25519 E2E
///     encryption of prompts/responses), and
///   - skips the dev→prod coordinator-URL migration so a `ws://` dev URL is not
///     rewritten to production.
///
/// It NEVER weakens end-to-end encryption. It exists only so an un-hardened,
/// un-attested dev build can connect to a throwaway dev-insecure coordinator,
/// register, and serve inference. Never set it against production.
public enum DevInsecure {
    /// True when `DARKBLOOM_DEV_INSECURE` is set to a truthy value.
    public static var isEnabled: Bool {
        switch ProcessInfo.processInfo.environment["DARKBLOOM_DEV_INSECURE"]?
            .trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    /// Optional coordinator URL override for the dev-insecure daemon path,
    /// e.g. `ws://10.0.0.5:8080/ws/provider`. Read from
    /// `DARKBLOOM_DEV_COORDINATOR_URL`. Lets the launchd daemon (which cannot
    /// take a `--url` flag) target the dev coordinator. Returns nil when unset
    /// or empty. Ranks below an explicit `--url` flag, above the config file.
    public static var coordinatorURLOverride: String? {
        guard let value = ProcessInfo.processInfo.environment["DARKBLOOM_DEV_COORDINATOR_URL"],
              !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        return value.trimmingCharacters(in: .whitespaces)
    }
}
