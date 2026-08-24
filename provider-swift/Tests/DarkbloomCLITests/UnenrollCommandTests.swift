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
            deleteToken: {},
            deleteAccount: {
                try FileManager.default.removeItem(at: files.accountPath)
            }
        )

        try await unlinkProviderAccount(
            token: nil,
            coordinatorURL: "wss://coordinator.test/ws/provider",
            dependencies: dependencies
        )

        #expect(!FileManager.default.fileExists(atPath: files.accountPath.path))
        #expect(revokeCount == 0)
    }
}
