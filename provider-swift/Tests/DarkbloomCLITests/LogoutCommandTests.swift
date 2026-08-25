import Foundation
import ProviderCore
import Testing
@testable import darkbloom

@Suite("Logout safely unlinks provider accounts")
struct LogoutCommandTests {
    @Test("local-only legacy recovery is explicit")
    func localOnlyFlagParses() throws {
        let command = try #require(
            Darkbloom.parseAsRoot(["logout", "--local-only"]) as? Logout
        )
        #expect(command.localOnly)
    }

    @Test("unlink stops recovery and provider before revoking and deleting credentials")
    @MainActor
    func orderedUnlink() async throws {
        let files = try IsolatedLoginFiles.make(
            prefix: "logout-test",
            token: "tok-123",
            account: "acct-456",
            issuer: "https://issuer.test"
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
                #expect(coordinatorURL == "https://coordinator.test")
                events.append("revoke")
            },
            deleteCredential: { credential in
                #expect(credential?.accountID == "acct-456")
                events.append("credentials")
                try FileManager.default.removeItem(at: files.tokenPath)
                try FileManager.default.removeItem(at: files.accountPath)
                try FileManager.default.removeItem(at: files.issuerPath)
            },
            deleteLocalCredential: {}
        )

        try await unlinkProviderAccount(
            credential: ProviderCredential(
                token: "tok-123",
                accountID: "acct-456",
                issuer: "https://coordinator.test"
            ),
            dependencies: dependencies
        )

        #expect(events == [
            "watchdog", "provider", "foreground", "revoke", "credentials",
        ])
        #expect(!FileManager.default.fileExists(atPath: files.accountPath.path),
            "a stale account id would keep `earnings`/daemon-state identity pointing at the previous account")
        #expect(!FileManager.default.fileExists(atPath: files.tokenPath.path))
        #expect(!FileManager.default.fileExists(atPath: files.issuerPath.path))
    }

    @Test("revocation failure preserves the only local credential copy")
    @MainActor
    func revocationFailurePreservesCredentials() async throws {
        struct RevocationFailure: Error {}
        let files = try IsolatedLoginFiles.make(
            prefix: "logout-test",
            token: "tok-123",
            account: "acct-456",
            issuer: "https://issuer.test"
        )
        defer { try? FileManager.default.removeItem(at: files.directory) }
        var deleted = false
        let dependencies = AccountUnlinkDependencies(
            stopWatchdog: {},
            stopProviderService: {},
            terminateRecordedProvider: { true },
            revokeToken: { _, _ in throw RevocationFailure() },
            deleteCredential: { _ in deleted = true },
            deleteLocalCredential: { deleted = true }
        )

        await #expect(throws: RevocationFailure.self) {
            try await unlinkProviderAccount(
                credential: ProviderCredential(
                    token: "tok-123",
                    accountID: "acct-456",
                    issuer: "https://issuer.test"
                ),
                dependencies: dependencies
            )
        }

        #expect(!deleted)
        #expect(FileManager.default.fileExists(atPath: files.tokenPath.path))
        #expect(FileManager.default.fileExists(atPath: files.accountPath.path))
        #expect(FileManager.default.fileExists(atPath: files.issuerPath.path))
    }

    @Test("local-only recovery clears legacy credentials without guessing an issuer")
    @MainActor
    func localOnlyRecovery() async throws {
        var events: [String] = []
        let dependencies = AccountUnlinkDependencies(
            stopWatchdog: { events.append("watchdog") },
            stopProviderService: { events.append("provider") },
            terminateRecordedProvider: {
                events.append("foreground")
                return true
            },
            revokeToken: { _, _ in events.append("revoke") },
            deleteCredential: { _ in events.append("matched-delete") },
            deleteLocalCredential: { events.append("local-delete") }
        )

        try await unlinkProviderAccount(
            credential: nil,
            localOnly: true,
            dependencies: dependencies
        )

        #expect(events == [
            "watchdog", "provider", "foreground", "local-delete",
        ])
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
            deleteCredential: { _ in revoked = true },
            deleteLocalCredential: { revoked = true }
        )

        await #expect(throws: AccountUnlinkError.providerDidNotStop) {
            try await unlinkProviderAccount(
                credential: ProviderCredential(
                    token: "tok-123",
                    accountID: "acct-456",
                    issuer: "https://issuer.test"
                ),
                dependencies: dependencies
            )
        }
        #expect(!revoked)
    }
}
