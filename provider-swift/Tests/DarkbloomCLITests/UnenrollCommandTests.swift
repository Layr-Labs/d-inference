import Foundation
import Testing
@testable import darkbloom

@Suite("Unenroll account cleanup")
struct UnenrollCommandTests {
    @Test("partial account state is removed without a revoke request")
    @MainActor
    func partialStateCleanup() async throws {
        let files = try IsolatedLoginFiles.make(
            prefix: "unenroll-test",
            token: nil,
            account: "acct-456"
        )
        defer { try? FileManager.default.removeItem(at: files.directory) }
        var revokeCount = 0
        let dependencies = AccountUnlinkDependencies(
            stopWatchdog: {},
            stopProviderService: {},
            terminateRecordedProvider: { true },
            revokeToken: { _, _ in revokeCount += 1 },
            deleteCredential: { credential in
                #expect(credential == nil)
                try FileManager.default.removeItem(at: files.accountPath)
            },
            deleteLocalCredential: {}
        )

        try await unlinkProviderAccount(
            credential: nil,
            dependencies: dependencies
        )

        #expect(!FileManager.default.fileExists(atPath: files.accountPath.path))
        #expect(revokeCount == 0)
    }
}
