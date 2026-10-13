import ArgumentParser
import Foundation
import ProviderCore

extension Cluster {
    /// This Mac's cluster service (`darkbloom cluster` starts it once the Mac
    /// is paired): answers the leader over the link control channel, applies
    /// the setup a member's leader syncs, and runs this Mac's part while the
    /// leader has the cluster serving. Runs until SIGTERM or SIGINT.
    struct Service: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "service",
            abstract: "Run this Mac's cluster service (started by `darkbloom cluster`).", shouldDisplay: false)
        @OptionGroup var configOptions: ConfigOptions
        @Option(help: "Absolute path of this Mac's cluster worker, when it is not installed beside darkbloom.")
        var worker: String?

        func validate() throws {
            for path in [configOptions.config, worker].compactMap({ $0 }) where !path.hasPrefix("/") {
                throw ValidationError("The cluster service takes absolute paths.")
            }
        }

        mutating func run() throws {
            Darkbloom.ensureLogging()
            let settings = try Cluster.Setup.serviceSettings(config: configOptions.config, modelDir: nil, worker: worker)
            let service = try ClusterService(settings: settings)
            let stop = DispatchSemaphore(value: 0)
            let signals = try DistributedStartSignals()
            defer { signals.close() }
            signals.attach { stop.signal() }
            let clean = try service.run(stop: stop) { text in
                let stamp = ISO8601DateFormatter().string(from: Date())
                FileHandle.standardOutput.write(Data("\(stamp) cluster service: \(text)\n".utf8))
            }
            if !clean { throw ExitCode(3) }
        }
    }
}
