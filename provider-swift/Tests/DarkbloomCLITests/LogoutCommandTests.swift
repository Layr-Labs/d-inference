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

    @Test func revocationUsesLiveCoordinatorInsteadOfChangedConfiguration() async throws {
        let identity = try #require(ProcessIdentity.current())
        let state = DaemonState(pid: identity.pid, processIdentity: identity,
            version: "test", writtenAt: 0, startedAt: 0,
            coordinatorURL: "wss://issuer.example/ws/provider")
        let coordinator = try #require(Logout.liveCoordinatorURL(from: state))
        let confirmed = await Logout.revokeSavedToken("synthetic-token", liveCoordinator: coordinator,
            configuredCoordinator: {
                Issue.record("configuration must not override the running provider's coordinator")
                return "wss://other.example/ws/provider"
            }, revoke: { token, target in
                #expect(token == "synthetic-token")
                #expect(target == "wss://issuer.example/ws/provider")
                return true
            })
        #expect(confirmed)
    }

    @Test func staleOrInconsistentProcessStateCannotChooseRevocationTarget() throws {
        let identity = try #require(ProcessIdentity.current())
        var state = DaemonState(pid: identity.pid, processIdentity: identity,
            version: "test", writtenAt: 0, startedAt: 0,
            coordinatorURL: "wss://issuer.example/ws/provider")
        state.processIdentity = .init(pid: identity.pid, startTimeMicros: identity.startTimeMicros + 1)
        #expect(Logout.liveCoordinatorURL(from: state) == nil)
        state.processIdentity = identity
        state.pid = identity.pid + 1
        #expect(Logout.liveCoordinatorURL(from: state) == nil)
        #expect(Logout.liveCoordinatorURL(from: nil) == nil)
    }

    @Test func malformedConfigurationDoesNotPreventLocalLogout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("provider.toml")
        try "[invalid".write(to: path, atomically: true, encoding: .utf8)
        var calls: [String] = []
        var saved: String? = "synthetic-token"
        let outcome = try await ProviderLogout.perform(
            stopProvider: { calls.append("stop") }, loadToken: { saved },
            revokeToken: { token in
                await Logout.revokeSavedToken(token, liveCoordinator: nil,
                    configuredCoordinator: {
                        calls.append("config")
                        return try loadRuntimeConfiguration(configPath: path.path).config.coordinator.url
                    }, revoke: { _, _ in
                        Issue.record("malformed configuration cannot select a revocation target")
                        return true
                    })
            }, deleteToken: { calls.append("delete"); saved = nil })
        #expect(calls == ["stop", "config", "delete"])
        #expect(saved == nil)
        #expect(outcome == .remoteUnconfirmed)
    }

    @Test func stoppedProviderWithoutLiveStateUsesConfiguredCoordinator() async {
        let confirmed = await Logout.revokeSavedToken("synthetic-token", liveCoordinator: nil,
            configuredCoordinator: { "wss://configured.example/ws/provider" },
            revoke: { _, target in
                #expect(target == "wss://configured.example/ws/provider")
                return true
            })
        #expect(confirmed)
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
