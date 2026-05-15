import Foundation
import ArgumentParser
import ProviderCore

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the provider in the foreground.",
        discussion: """
        Foreground provider mode for operators and local debugging. This connects
        to the coordinator and keeps running until interrupted. Use `darkbloom start`
        for the launchd-managed background service.
        """
    )

    @OptionGroup var configOptions: ConfigOptions

    @Option(help: "Override coordinator WebSocket URL.")
    var coordinatorURL: String?

    @Option(help: "Model ID to serve (repeatable).")
    var model: [String] = []

    @Flag(help: "Serve all local models.")
    var all = false

    @Option(help: "Idle timeout in minutes before unloading the model.")
    var idleTimeout: UInt64?

    mutating func run() async throws {
        var args: [String] = ["--foreground"]
        if let config = configOptions.config {
            args += ["--config", config]
        }
        if let coordinatorURL {
            args += ["--coordinator-url", coordinatorURL]
        }
        for modelID in model {
            args += ["--model", modelID]
        }
        if all {
            args.append("--all")
        }
        if let idleTimeout {
            args += ["--idle-timeout", "\(idleTimeout)"]
        }

        var start = try Start.parse(args)
        try await start.run()
    }
}
