import ArgumentParser
import Foundation
import ProviderCore

extension Autopilot {
    struct Enable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Enroll in experimental Autopilot using the normal startup selector.")
        @OptionGroup var configOptions: ConfigOptions
        mutating func run() async throws {
            var start = try Start.parse(["--autopilot"]); start.configOptions = configOptions
            try await start.run()
        }
    }
    struct Models: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Refresh the downloaded network-model inventory using the normal startup selector and safe restart.")
        @OptionGroup var configOptions: ConfigOptions
        mutating func run() async throws {
            var start = try Start.parse(["--autopilot"]); start.configOptions = configOptions
            try await start.run()
        }
    }
}
