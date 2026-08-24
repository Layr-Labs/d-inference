import Foundation
import Testing

@Suite("Logout clears every login-state artifact")
struct LogoutCommandTests {
    @Test("logout removes the account id alongside the token")
    func clearsAccountID() throws {
        let files = try IsolatedLoginFiles.make(
            prefix: "logout-test",
            token: "tok-123",
            account: "acct-456"
        )
        defer { try? FileManager.default.removeItem(at: files.directory) }

        let result = try runDarkbloomCLI(arguments: ["logout"], files: files)

        #expect(!FileManager.default.fileExists(atPath: files.accountPath.path),
            "a stale account id would keep `earnings`/daemon-state identity pointing at the previous account")
        #expect(!FileManager.default.fileExists(atPath: files.tokenPath.path))
        #expect(result.status == 0)
        #expect(result.output.contains("Logged out."))
    }

    @Test("logout succeeds when only the account id exists (partial state)")
    func clearsAccountWithoutToken() throws {
        let files = try IsolatedLoginFiles.make(
            prefix: "logout-test",
            token: nil,
            account: "acct-456"
        )
        defer { try? FileManager.default.removeItem(at: files.directory) }

        let result = try runDarkbloomCLI(arguments: ["logout"], files: files)

        #expect(!FileManager.default.fileExists(atPath: files.accountPath.path))
        #expect(!FileManager.default.fileExists(atPath: files.tokenPath.path))
        #expect(result.status == 0)
        #expect(result.output.contains("Logged out."))
    }
}
