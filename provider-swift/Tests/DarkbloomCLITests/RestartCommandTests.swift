import ArgumentParser
import Testing

@testable import darkbloom

/// Unit tests for the `darkbloom restart` subcommand wiring. These verify the
/// command is registered and parses, without executing launchctl (that side
/// effect is covered by manual/integration verification).
@Suite("Restart command")
struct RestartCommandTests {

    @Test("restart is registered and parses to a Restart command")
    func restartParses() throws {
        let command = try Darkbloom.parseAsRoot(["restart"])
        #expect(command is Restart)
    }
}
