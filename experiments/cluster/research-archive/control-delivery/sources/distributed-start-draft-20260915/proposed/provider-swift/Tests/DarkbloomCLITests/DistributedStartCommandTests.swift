import ArgumentParser
import Testing
@testable import darkbloom

@Suite("Distributed local startup selection")
struct DistributedStartCommandTests {
    @Test func explicitLocalOptInAndSavedConfigParseWithoutIO() throws {
        let command = try Start.parse(["--local", "--distributed", "--config", "/fixture/provider.toml"])
        #expect(command.distributed && command.local && !command.foreground)
        #expect(command.configOptions.config == "/fixture/provider.toml")
        #expect(try Start.parse(["--local"]).distributed == false)
        #expect(try Start.parse([]).distributed == false)
    }

    @Test func incompatibleModesAndSoloOverridesRefuseBeforeStartup() {
        for values in [["--distributed"], ["--distributed", "--local-endpoint"],
                       ["--distributed", "--local", "--foreground"],
                       ["--distributed", "--local", "--all"],
                       ["--distributed", "--local", "--model", "other"],
                       ["--distributed", "--local", "--idle-timeout", "2"],
                       ["--distributed", "--local", "--coordinator-url", "wss://example.invalid"]] {
            #expect(throws: (any Error).self) { _ = try Start.parse(values) }
        }
    }
}
