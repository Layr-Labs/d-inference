import ArgumentParser
import Foundation
import ProviderCore

extension Autopilot {
    struct Disable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Disable new Autopilot changes and restore the saved idle policy.")
        @OptionGroup var configOptions: ConfigOptions
        mutating func run() async throws {
            try setModelAutopilot(enabled: false, configPath: configOptions.config)
            print("Autopilot disabled. The running provider applies this at its next policy refresh; an accepted transition finishes safely.")
        }
    }
    struct Pause: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Pause demand-based model changes.",
            discussion: "Retired, unadvertised models may still unload. Pins and active work remain protected.")
        @OptionGroup var configOptions: ConfigOptions
        mutating func run() async throws { try changeAutopilotPolicy(configPath: configOptions.config) { $0.paused = true }; print("Autopilot pause requested.") }
    }
    struct Resume: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Resume an existing Autopilot enrollment.")
        @OptionGroup var configOptions: ConfigOptions
        mutating func run() async throws { try changeAutopilotPolicy(configPath: configOptions.config) { $0.paused = false }; print("Autopilot resume requested.") }
    }
    struct Pin: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Protect selected models while Autopilot controls residency.",
            discussion: "Without active control or an explicit pause, the saved idle policy applies after any accepted change finishes.")
        @OptionGroup var configOptions: ConfigOptions
        @Argument var models: [String]
        mutating func run() async throws {
            try changeAutopilotPolicy(configPath: configOptions.config) { settings in
                guard Set(models).isSubset(of: Set(settings.selectedModels)) else { throw ValidationError("Pins must be selected Autopilot models.") }
                settings.pinnedModels = Array(Set(settings.pinnedModels + models)).sorted()
            }
            print("Pins updated.")
        }
    }
    struct Unpin: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove automatic-unload protection from selected models.")
        @OptionGroup var configOptions: ConfigOptions
        @Argument var models: [String]
        mutating func run() async throws {
            try changeAutopilotPolicy(configPath: configOptions.config) { $0.pinnedModels.removeAll { models.contains($0) } }
            print("Pins updated.")
        }
    }
}
