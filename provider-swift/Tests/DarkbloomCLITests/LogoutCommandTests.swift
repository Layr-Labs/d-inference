import Foundation
import Testing
@testable import darkbloom
import ProviderCore

@Suite("Logout clears every login-state artifact")
struct LogoutCommandTests {
    /// Creates fresh token/account paths under a temp dir and points the
    /// stores' env overrides at them. Caller unsets in defer.
    private func loginFiles(
        token: String?, account: String?
    ) throws -> (dir: URL, tokenPath: URL, accountPath: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("logout-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tokenPath = dir.appendingPathComponent("auth_token")
        let accountPath = dir.appendingPathComponent("provider_account")
        if let token {
            try token.write(to: tokenPath, atomically: true, encoding: .utf8)
        }
        if let account {
            try account.write(to: accountPath, atomically: true, encoding: .utf8)
        }
        setenv("DARKBLOOM_AUTH_TOKEN_PATH", tokenPath.path, 1)
        setenv("DARKBLOOM_PROVIDER_ACCOUNT_PATH", accountPath.path, 1)
        return (dir, tokenPath, accountPath)
    }

    private func cleanup(_ dir: URL) {
        unsetenv("DARKBLOOM_AUTH_TOKEN_PATH")
        unsetenv("DARKBLOOM_PROVIDER_ACCOUNT_PATH")
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("logout removes the account id alongside the token")
    func clearsAccountID() async throws {
        let (dir, _, _) = try loginFiles(token: "tok-123", account: "acct-456")
        defer { cleanup(dir) }

        #expect(ProviderAccountStore.load() == "acct-456")
        var logout = Logout()
        try await logout.run()
        #expect(ProviderAccountStore.load() == nil,
            "a stale account id would keep `earnings`/daemon-state identity pointing at the previous account")
        #expect(AuthTokenStore.load() == nil)
    }

    @Test("logout succeeds when only the account id exists (partial state)")
    func clearsAccountWithoutToken() async throws {
        let (dir, _, _) = try loginFiles(token: nil, account: "acct-456")
        defer { cleanup(dir) }

        var logout = Logout()
        try await logout.run()
        #expect(ProviderAccountStore.load() == nil)
    }
}
