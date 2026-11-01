import ArgumentParser
import Testing
@testable import darkbloom

@Suite("Cluster configure CLI")
struct ClusterCommandTests {
    private var arguments: [String] {
        ["--input", "/Users/fixture/setup.json", "--capability", "/Users/fixture/capability.json",
         "--capability-sha256", String(repeating: "a", count: 64)]
    }

    @Test("configure parses explicit pins and optional output/provider path without IO")
    func accepted() throws {
        let command = try Cluster.Configure.parse(arguments + ["--json", "--config", "/Users/fixture/provider.toml"])
        #expect(command.json)
        #expect(command.input == "/Users/fixture/setup.json")
        #expect(command.configOptions.config == "/Users/fixture/provider.toml")
    }

    @Test("missing pin, relative paths and enable/environment/capacity flags refuse")
    func rejected() {
        for values in [Array(arguments.dropLast(2)), arguments + ["--enable"], arguments + ["--capacity", "123"],
                       arguments + ["--environment", "KEY=VALUE"],
                       ["--input", "relative", "--capability", "/capability", "--capability-sha256", String(repeating: "a", count: 64)],
                       ["--input", "/input", "--capability", "/capability", "--capability-sha256", String(repeating: "A", count: 64)]] {
            #expect(throws: (any Error).self) { _ = try Cluster.Configure.parse(values) }
        }
    }

    @Test("root dispatch registers configure while existing solo commands remain")
    func dispatch() throws {
        let command = try Darkbloom.parseAsRoot(["cluster", "configure"] + arguments)
        #expect(command is Cluster.Configure)
        #expect(Darkbloom.configuration.subcommands.contains { $0 == Start.self })
        #expect(Darkbloom.configuration.subcommands.contains { $0 == Local.self })
    }
}
