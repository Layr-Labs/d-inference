import ArgumentParser
import Testing
@testable import darkbloom

@Suite("Local start CLI contract")
struct LocalStartContractTests {
    @Test("App local launch has an explicit non-replacing contract")
    func appLaunchArguments() throws {
        let command = try Start.parse(["--local", "--model", "org/model", "--no-replace"])
        #expect(command.local)
        #expect(command.noReplace)
        #expect(command.model == ["org/model"])
        #expect(!command.localEndpoint)
        #expect(!command.noAuth)
    }

    @Test("Non-replacing mode cannot silently fall through to launchd")
    func requiresLocalMode() {
        #expect(throws: (any Error).self) {
            try Start.parse(["--model", "org/model", "--no-replace"])
        }
    }

    @Test("Existing network start retains replacement semantics")
    func networkDefaultIsUnchanged() throws {
        let command = try Start.parse(["--model", "org/model", "--local-endpoint"])
        #expect(!command.noReplace)
        #expect(!command.local)
        #expect(command.localEndpoint)
    }
}
