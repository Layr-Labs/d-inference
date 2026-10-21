import ArgumentParser
import Foundation
import Testing
@testable import darkbloom
@testable import ProviderCore

@Suite struct LogoutCommandTests {
    @Test func usesSharedConfigurationAndDrainOptions() throws {
        let command = try #require(try Darkbloom.parseAsRoot([
            "logout", "--config", "/tmp/logout-fixture.toml", "--timeout", "12", "--force",
        ]) as? Logout)
        #expect(command.configOptions.config == "/tmp/logout-fixture.toml")
        #expect(command.drain.timeout == 12)
        #expect(command.drain.force)
        let defaults = try Logout.parse([])
        #expect(defaults.configOptions.config == nil)
        #expect(defaults.drain.timeout == 600)
        #expect(!defaults.drain.force)
        #expect(throws: (any Error).self) { try Logout.parse(["--timeout", "-1"]) }
    }

    @Test func liveForegroundIdentityMustExitBeforeCredentialRemoval() throws {
        // This checks a real kernel identity without reading operator state,
        // signalling a process or invoking launchctl/Stop in the test runner.
        let live = try #require(ProcessIdentity.current())
        #expect(throws: ValidationError.self) { try Logout.requireExited([live]) }
        try Logout.requireExited([])
        try Logout.requireExited([.init(pid: live.pid, startTimeMicros: live.startTimeMicros + 1)])
    }

    @Test func reusedPIDCannotBecomeAnUnrelatedProvider() throws {
        let current = try #require(ProcessIdentity.current())
        let old = ProcessIdentity(pid: current.pid, startTimeMicros: current.startTimeMicros + 1)
        var state = DaemonState(pid: old.pid, processIdentity: old,
            version: "test", writtenAt: 0, startedAt: 0)
        let identities = Logout.providerIdentities(state: state, launchProcess: nil)
        #expect(identities == [old])
        try Logout.requireExited(identities)
        #expect(Logout.providerIdentities(state: nil, launchProcess: nil).isEmpty)
        state.pid += 1
        #expect(Logout.providerIdentities(state: state, launchProcess: nil).isEmpty)
        #expect(throws: ValidationError.self) {
            try Logout.requireExited(Logout.providerIdentities(state: nil, launchProcess: current))
        }
    }

    @Test func revocationUsesSavedIssuerWithoutRunningProvider() async {
        let confirmed = await Logout.revokeSavedToken("synthetic-token",
            issuer: { token in
                #expect(token == "synthetic-token")
                return "wss://issuer.example/ws/provider"
            }, revoke: { token, target in
                #expect(token == "synthetic-token")
                #expect(target == "wss://issuer.example/ws/provider")
                return true
            })
        #expect(confirmed)
    }

    @Test func malformedConfigurationDoesNotPreventLocalLogout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("provider.toml")
        try "[invalid".write(to: path, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try loadRuntimeConfiguration(configPath: path.path) }
        _ = try Logout.parse(["--config", path.path])
        var calls: [String] = []
        var saved: String? = "synthetic-token"
        let outcome = try await ProviderLogout.perform(
            stopProvider: { calls.append("stop") }, loadToken: { saved },
            revokeToken: { token in
                await Logout.revokeSavedToken(token, issuer: { _ in nil }, revoke: { _, _ in
                        Issue.record("unknown issuer cannot select a revocation target")
                        return true
                    })
            }, deleteToken: { calls.append("delete"); saved = nil })
        #expect(calls == ["stop", "delete"])
        #expect(saved == nil)
        #expect(outcome == .remoteUnconfirmed)
    }

    @Test func unknownIssuerNeverSendsTokenToGuessedCoordinator() async {
        let confirmed = await Logout.revokeSavedToken("synthetic-token", issuer: { _ in nil },
            revoke: { _, _ in
                Issue.record("must not guess an issuer from configuration or daemon state")
                return true
            })
        #expect(!confirmed)
    }

    @Test func messagesDistinguishLocalDeletionFromConfirmedRevocation() {
        let revoked = Logout.completionLines(for: .revoked).joined(separator: "\n")
        #expect(revoked.contains("This provider token was revoked"))
        #expect(revoked.contains("Automatic restart is disabled"))
        for outcome: ProviderLogout.Outcome in [.remoteUnconfirmed, .noCredential] {
            let output = Logout.completionLines(for: outcome).joined(separator: "\n")
            #expect(output.contains("Remote token invalidation"))
            #expect(output.contains("not confirmed") || output.contains("could not be confirmed"))
            #expect(!output.contains("token was revoked"))
            #expect(!output.contains("no longer linked"))
            #expect(!output.contains("unlinked"))
        }
        #expect(Logout.completionLines(for: .remoteUnconfirmed).contains("Logged out locally. The saved provider credential was removed."))
        #expect(Logout.completionLines(for: .noCredential).contains { $0.contains("No saved provider credential") })
    }
}
