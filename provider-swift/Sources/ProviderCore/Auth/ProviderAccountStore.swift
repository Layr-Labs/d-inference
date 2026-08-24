/// ProviderAccountStore -- persistence for the coordinator account id this
/// machine's earnings are keyed on.
///
/// When an operator links this Mac via the device-code flow (`darkbloom
/// login`), the coordinator's `POST /v1/device/token` response carries an
/// `account_id`: the ledger account the coordinator credits this provider's
/// payouts to (see `CreditProviderAccount` server-side). Persisting it lets
/// read-only daemon-state surfaces name the linked operator. Earnings requests
/// still authenticate with the provider token and recover this identifier
/// from `GET /v1/provider/account-earnings` if an older install lacks the file.
///
/// The account id is an identifier, not a credential, so it lives next to —
/// not inside — the auth token, with the same 0600 permissions policy.
import Foundation

public enum ProviderAccountStore: Sendable {

    /// Path to the canonical stored account id. Test harnesses can override
    /// with `DARKBLOOM_PROVIDER_ACCOUNT_PATH` to avoid touching the user's
    /// login state (mirrors `DARKBLOOM_AUTH_TOKEN_PATH`).
    public static func accountPath() -> URL {
        if let override = accountPathOverride(), !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".darkbloom")
            .appendingPathComponent("provider_account")
    }

    private static func accountPathOverride() -> String? {
        ProcessInfo.processInfo.environment["DARKBLOOM_PROVIDER_ACCOUNT_PATH"]
    }

    /// Load the stored account id, if any. A malformed or empty file reads as
    /// "not linked" rather than failing: the callers treat absence as
    /// "operator has not logged in on this machine (yet)".
    public static func load() -> String? {
        guard let content = try? String(contentsOf: accountPath(), encoding: .utf8) else {
            return nil
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Save an account id with the same restricted permissions (0600) as the
    /// auth token, keeping login-state files uniform under `~/.darkbloom`.
    public static func save(_ accountID: String) throws {
        let path = accountPath()
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try accountID.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path.path
        )
    }

    /// Delete the stored account id. A missing file is already deleted; other
    /// filesystem failures are surfaced so logout cannot report false success.
    public static func delete() throws {
        let path = accountPath()
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }
}
