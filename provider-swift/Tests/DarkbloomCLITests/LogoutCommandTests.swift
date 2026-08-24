import Foundation
import Testing
@testable import darkbloom

@Suite("Logout safely unlinks provider accounts")
struct LogoutCommandTests {
    @Test("unlink stops recovery and provider before revoking and deleting credentials")
    @MainActor
    func orderedUnlink() async throws {
        let files = try IsolatedLoginFiles.make(
            prefix: "logout-test",
            token: "tok-123",
            account: "acct-456"
        )
        defer { try? FileManager.default.removeItem(at: files.directory) }
        var events: [String] = []
        let dependencies = AccountUnlinkDependencies(
            stopWatchdog: { events.append("watchdog") },
            stopProviderService: { events.append("provider") },
            terminateRecordedProvider: {
                events.append("foreground")
                return true
            },
            revokeToken: { token, coordinatorURL in
                #expect(token == "tok-123")
                #expect(coordinatorURL == "wss://coordinator.test/ws/provider")
                events.append("revoke")
            },
            deleteToken: {
                events.append("token")
                try FileManager.default.removeItem(at: files.tokenPath)
            },
            deleteAccount: {
                events.append("account")
                try FileManager.default.removeItem(at: files.accountPath)
            }
        )

        try await unlinkProviderAccount(
            token: "tok-123",
            coordinatorURL: "wss://coordinator.test/ws/provider",
            dependencies: dependencies
        )

        #expect(events == ["watchdog", "provider", "foreground", "revoke", "token", "account"])
        #expect(!FileManager.default.fileExists(atPath: files.accountPath.path),
            "a stale account id would keep `earnings`/daemon-state identity pointing at the previous account")
        #expect(!FileManager.default.fileExists(atPath: files.tokenPath.path))
    }

    @Test("revocation failure preserves the only local credential copy")
    @MainActor
    func revocationFailurePreservesCredentials() async throws {
        struct RevocationFailure: Error {}
        let files = try IsolatedLoginFiles.make(
            prefix: "logout-test",
            token: "tok-123",
            account: "acct-456"
        )
        defer { try? FileManager.default.removeItem(at: files.directory) }
        var deleted = false
        let dependencies = AccountUnlinkDependencies(
            stopWatchdog: {},
            stopProviderService: {},
            terminateRecordedProvider: { true },
            revokeToken: { _, _ in throw RevocationFailure() },
            deleteToken: { deleted = true },
            deleteAccount: { deleted = true }
        )

        await #expect(throws: RevocationFailure.self) {
            try await unlinkProviderAccount(
                token: "tok-123",
                coordinatorURL: "wss://coordinator.test/ws/provider",
                dependencies: dependencies
            )
        }

        #expect(!deleted)
        #expect(FileManager.default.fileExists(atPath: files.tokenPath.path))
        #expect(FileManager.default.fileExists(atPath: files.accountPath.path))
    }

    @Test("failure to stop a foreground provider preserves credentials")
    @MainActor
    func foregroundStopFailurePreservesCredentials() async {
        var revoked = false
        let dependencies = AccountUnlinkDependencies(
            stopWatchdog: {},
            stopProviderService: {},
            terminateRecordedProvider: { false },
            revokeToken: { _, _ in revoked = true },
            deleteToken: { revoked = true },
            deleteAccount: { revoked = true }
        )

        await #expect(throws: AccountUnlinkError.providerDidNotStop) {
            try await unlinkProviderAccount(
                token: "tok-123",
                coordinatorURL: "wss://coordinator.test/ws/provider",
                dependencies: dependencies
            )
        }
        #expect(!revoked)
    }
}
