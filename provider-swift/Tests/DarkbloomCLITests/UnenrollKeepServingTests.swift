import ArgumentParser
import Testing
@testable import darkbloom

@Suite struct UnenrollKeepServingTests {
    @Test func migrationIsAnExplicitSeparateCommandMode() throws {
        let command = try #require(try Darkbloom.parseAsRoot([
            "unenroll", "--keep-serving", "--no-open", "--config", "/tmp/provider.toml"
        ]) as? Unenroll)
        #expect(command.keepServing)
        #expect(command.noOpen)
        #expect(!command.force)
        #expect(command.configOptions.config == "/tmp/provider.toml")
        let legacy = try #require(try Darkbloom.parseAsRoot(["unenroll", "--force"]) as? Unenroll)
        #expect(!legacy.keepServing)
    }

    @Test func migrationCannotInvokeForcedCleanup() throws {
        let command = try #require(try Darkbloom.parseAsRoot(["unenroll", "--keep-serving", "--force"]) as? Unenroll)
        #expect(throws: ValidationError.self) { try command.prepareMDMRemovalWhileServing() }
    }
}
