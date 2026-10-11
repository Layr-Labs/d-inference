import ArgumentParser
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
