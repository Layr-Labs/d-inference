import ArgumentParser
import Foundation
import ProviderCore

extension Autopilot {
    struct Enable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Enroll downloaded network models in experimental Autopilot (shadow mode; no downloads).")
        @OptionGroup var configOptions: ConfigOptions
        mutating func run() async throws {
            var start = try Start.parse(["--autopilot"]); start.configOptions = configOptions
            try await start.run()
        }
    }
    struct Models: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Refresh the downloaded network-model inventory; preserve preferences and safely restart.")
        @OptionGroup var configOptions: ConfigOptions
        mutating func run() async throws {
            var start = try Start.parse(["--autopilot"]); start.configOptions = configOptions
            try await start.run()
        }
    }
}
