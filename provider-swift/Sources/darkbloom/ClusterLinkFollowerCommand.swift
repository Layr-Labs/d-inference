import ArgumentParser
import Foundation
import ProviderCore

extension Cluster {
    /// The follower member of a setup reached over the link control channel
    /// (PROD-PLAN S08): dials the leader's link address and serves each
    /// session the leader opens through this Mac's own installed owner. No SSH
    /// configuration exists for such a setup. Runs until SIGTERM or SIGINT,
    /// then fences what runs and waits (bounded) for its owner's release.
    struct LinkFollower: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "link-follower",
            abstract: "Serve this Mac's rank to the leader over the link control channel (follower setups only).", shouldDisplay: false)
        @OptionGroup var configOptions: ConfigOptions

        func validate() throws {
            if let path = configOptions.config, !path.hasPrefix("/") {
                throw ValidationError("The provider configuration requires an absolute path.")
            }
        }

        mutating func run() throws {
            Darkbloom.ensureLogging()
            let providerPath = try configOptions.config.map { URL(fileURLWithPath: $0) } ?? ConfigManager.defaultConfigPath()
            let selected = try ClusterConfigurationStore.installedReference(providerConfiguration: providerPath)
            // The owner this member launches reads the default setup: both must be the same.
            let owner = try ClusterConfigurationStore.installedReference(providerConfiguration: ConfigManager.defaultConfigPath())
            guard selected == owner else {
                throw ValidationError("The selected cluster setup and the installed owner's default setup differ.")
            }
            let stop = DispatchSemaphore(value: 0)
            let signals = try DistributedStartSignals()
            defer { signals.close() }
            signals.attach { stop.signal() }
            let idle = try DistributedInstalledLinkFollower.serve(reference: selected, stop: stop) { event in
                LinkFollower.emit(event)
            }
            LinkFollower.line("stopped " + (idle ? "idle" : "with a session still releasing"))
            if !idle { throw ExitCode(3) }
        }

        static func emit(_ event: DistributedInstalledLinkFollower.Event) {
            switch event {
            case .ready: line("ready")
            case .connected: line("connected")
            case .disconnected: line("disconnected")
            case .opened: line("session opened")
            case .refused(let reason): line("session refused: \(reason)")
            case .fenced(let reason): line("session fenced: \(reason)")
            case .cleanup: line("session cleanup observed")
            case .released(let cleanly): line("session released " + (cleanly ? "cleanly" : "without its owner's proof"))
            case .linkRefused(let reason):
                line("link refused: \(reason)")
                // macOS answers a dial with "host unreachable" before trying the
                // cable when this process may not use the local network.
                if reason.hasSuffix("(unreachable)") {
                    line("this process may not reach the local network: macOS refused the dial before the cable was tried. "
                        + "Allow darkbloom under System Settings > Privacy & Security > Local Network (once), "
                        + "or start the follower from a session that has that access.")
                }
            }
        }

        static func line(_ text: String) {
            let stamp = ISO8601DateFormatter().string(from: Date())
            FileHandle.standardOutput.write(Data("\(stamp) link-follower: \(text)\n".utf8))
        }
    }
}
