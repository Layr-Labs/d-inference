import Foundation
import ArgumentParser
import ProviderCore

extension Cluster {
    struct Link: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "link",
            abstract: "Check this Mac's Thunderbolt RDMA link, watch it, or give its port the address it lacks after your approval.",
            discussion: """
                Without options this reads local state only and contacts no peer. --fix adds one link-local IPv4 \
                address to the one active Thunderbolt port that lacks an address of its own: macOS shows its own \
                approval prompt, and Darkbloom never uses sudo. That address is lost at a restart or when the cable \
                is replugged; run --fix again afterwards. --remove takes away an address that --fix added.
                """)
        @Flag(help: "Print JSON instead of text; with --watch, one object per line.") var json = false
        @Flag(help: "Give the active Thunderbolt port that lacks an IPv4 address a link-local one, after approval in a macOS prompt.")
        var fix = false
        @Flag(help: "Remove the address an earlier --fix added, after approval in a macOS prompt.") var remove = false
        @Flag(help: "Poll the link and print each change until interrupted.") var watch = false
        @Option(help: "With --fix or --remove: the RDMA device to act on, such as rdma_en6.") var device: String?

        func validate() throws {
            guard [fix, remove, watch].filter({ $0 }).count <= 1 else {
                throw ValidationError("Choose at most one of --fix, --remove and --watch.")
            }
            guard let device else { return }
            guard fix || remove else { throw ValidationError("--device applies only to --fix and --remove.") }
            guard ClusterLinkRepair.isDeviceName(device) else {
                throw ValidationError("Expected an RDMA device name such as rdma_en6.")
            }
        }

        mutating func run() async throws {
            Darkbloom.ensureLogging()
            // Local RDMA and interface state only: no provider configuration,
            // hardware/model discovery, update banner, enrollment or connection.
            if watch {
                try await ClusterLinkWatchLoop.printChanges(json: json)
            } else if fix || remove {
                try await repair()
            } else {
                let report = await Task.detached { ClusterLinkReadinessProbe.inspectLocalLink() }.value
                if json { try printJSON(report) } else { for line in report.summaryLines { print(line) } }
                if report.state != .ready { throw ExitCode.failure }
            }
        }

        private func repair() async throws {
            let device = device, removing = remove
            // Blocks while the person at the screen answers the macOS prompt.
            let result = await Task.detached {
                removing ? ClusterLinkRepair.remove(device: device) : ClusterLinkRepair.fix(device: device)
            }.value
            if json { try printJSON(result) } else { for line in result.summaryLines { print(line) } }
            // The only place the address is shown: where no prompt could be, as
            // a command for an administrator, on standard error and never in JSON.
            // The message that announces it goes out first, also on a shared pipe.
            if let manualCommand = result.manualCommand {
                fflush(stdout)
                printError(manualCommand)
            }
            if result.outcome.exitCode != 0 { throw ExitCode(result.outcome.exitCode) }
        }
    }
}
