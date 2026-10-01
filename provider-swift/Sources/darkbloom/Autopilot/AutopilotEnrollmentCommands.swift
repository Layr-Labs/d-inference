import ArgumentParser
import Foundation
import ProviderCore

extension Autopilot {
    struct Enable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Choose models and enroll in experimental Autopilot (shadow rollout by default).")
        @OptionGroup var configOptions: ConfigOptions
        mutating func run() async throws {
            var start = try Start.parse(["--autopilot"]); start.configOptions = configOptions
            try await start.run()
        }
    }
    struct Models: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Choose the Autopilot model set; safely restart after downloads finish.")
        @OptionGroup var configOptions: ConfigOptions
        mutating func run() async throws {
            var start = try Start.parse(["--autopilot"]); start.configOptions = configOptions
            try await start.run()
        }
    }
}
