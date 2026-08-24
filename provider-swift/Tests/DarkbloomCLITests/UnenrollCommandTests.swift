import Foundation
import Testing

@Suite("Unenroll clears every login-state artifact")
struct UnenrollCommandTests {
    @Test("forced cleanup removes the linked account alongside the auth token")
    func forcedCleanupClearsLoginIdentity() throws {
        let files = try IsolatedLoginFiles.make(
            prefix: "unenroll-test",
            token: "tok-123",
            account: "acct-456"
        )
        defer { try? FileManager.default.removeItem(at: files.directory) }

        let result = try runDarkbloomCLI(
            arguments: ["unenroll", "--force", "--no-open"],
            files: files
        )

        #expect(result.status == 0)
        #expect(!FileManager.default.fileExists(atPath: files.tokenPath.path))
        #expect(!FileManager.default.fileExists(atPath: files.accountPath.path))
        #expect(result.output.contains("Linked account: ~/.darkbloom/provider_account"))
        #expect(result.output.contains("Local data cleaned up."))
    }
}
