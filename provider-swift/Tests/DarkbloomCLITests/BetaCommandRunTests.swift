import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// `darkbloom beta list|status|enable|disable` against a temporary config.
/// The commands load the runtime snapshot, which sets the process-wide model
/// cache, so the runs are in a child process (`CLICommandSandbox`).
@Suite("Beta command run")
struct BetaCommandRunTests {

    @Test("list prints every feature with its state, and --json reports the same features")
    func listTableAndJSON() async throws {
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardOutputContent]
        ) {
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            print("== TABLE")
            try await runCLICommand(Beta.List.self, ["beta", "list", "--config", sandbox.config.path])
            print("== JSON")
            try await runCLICommand(Beta.List.self, ["beta", "list", "--config", sandbox.config.path, "--json"])
            print("== END")
        }
        let output = decodedText(result.standardOutputContent)
        let table = try #require(outputSection(output, from: "== TABLE", to: "== JSON"))
        #expect(table.hasPrefix("Beta features (config: "))
        #expect(table.contains("Change with:  darkbloom beta enable|disable <feature>   (then: darkbloom restart)\n"))
        #expect(table.hasSuffix("Details with: darkbloom beta status <feature>\n"))
        for feature in BetaFeatures.all {
            #expect(table.contains("] \(feature.id)  —  \(feature.summary)\n"))
        }

        let json = try #require(outputSection(output, from: "== JSON", to: "== END"))
        let reports = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        #expect(reports.compactMap { $0["id"] as? String } == BetaFeatures.all.map(\.id))
        #expect(reports.compactMap { $0["requiresRestart"] as? Bool } == BetaFeatures.all.map(\.requiresRestart))
    }

    @Test("status shows every feature or one, and rejects an unknown feature")
    func status() async throws {
        let first = try #require(BetaFeatures.all.first)
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardOutputContent]
        ) {
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            print("== ALL")
            try await runCLICommand(Beta.Status.self, ["beta", "status", "--config", sandbox.config.path])
            let one = try #require(BetaFeatures.all.first)
            print("== ONE")
            try await runCLICommand(Beta.Status.self, ["beta", "status", one.id, "--config", sandbox.config.path])
            print("== END")
            let error = try await runFailingCLICommand(
                Beta.Status.self, ["beta", "status", "no-such-feature", "--config", sandbox.config.path])
            #expect(error is ValidationError)
            #expect(String(describing: error).contains("Unknown beta feature 'no-such-feature'."))
        }
        let output = decodedText(result.standardOutputContent)
        let all = try #require(outputSection(output, from: "== ALL", to: "== ONE"))
        #expect(all.hasPrefix("Config: "))
        for feature in BetaFeatures.all {
            #expect(all.contains("\n\(feature.title) (\(feature.id)): "))
        }
        let one = try #require(outputSection(output, from: "== ONE", to: "== END"))
        #expect(one.contains("\n\(first.title) (\(first.id)): "))
        #expect(one.contains("  \(first.details)\n"))
        #expect(one.contains("Requires `darkbloom restart` after a change.") == first.requiresRestart)
        #expect(BetaFeatures.all.dropFirst().allSatisfy { !one.contains("(\($0.id)): ") })
    }

    @Test("enable and disable write the feature state to the selected config")
    func enableAndDisable() async {
        await #expect(processExitsWith: .success) {
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            let feature = try #require(BetaFeatures.all.first)
            try await runCLICommand(
                Beta.Disable.self, ["beta", "disable", feature.id, "--config", sandbox.config.path])
            #expect(feature.state(in: try ConfigManager.load(from: sandbox.config)) == .off)
            try await runCLICommand(
                Beta.Enable.self, ["beta", "enable", feature.id, "--config", sandbox.config.path])
            #expect(feature.state(in: try ConfigManager.load(from: sandbox.config)) == .on)
            let error = try await runFailingCLICommand(
                Beta.Enable.self, ["beta", "enable", "no-such-feature", "--config", sandbox.config.path])
            #expect(error is ValidationError)
        }
    }

    @Test("beta defaults to the list")
    func defaultSubcommand() throws {
        #expect(try Darkbloom.parseAsRoot(["beta"]) is Beta.List)
        #expect(betaFeatureListMark(.on) == "on ")
        #expect(betaFeatureListMark(.off) == "off")
        #expect(betaFeatureListMark(.auto) == "auto")
    }
}
