import Foundation
import ArgumentParser
import ProviderCore

extension Cluster {
    struct Link: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "link",
            abstract: "Check this Mac's Thunderbolt RDMA link, watch it, or set its port up for the cluster after your approval.",
            discussion: """
                Without options this reads local state only and contacts no peer, including how the network \
                around the active port is put together: bridge membership, Internet Sharing, default routes, \
                DNS and DHCP through the port, and the port's network services. --fix isolates the active \
                Thunderbolt port: it takes the port out of its bridge, gives it its own network service with a \
                fixed address, no router and no DNS, and switches other services on that port off, so macOS \
                keeps the address, also after a restart, and nothing else uses the cable. Internet Sharing is \
                never changed; when it shares to the port directly, --fix says what to turn off and stops. \
                macOS shows its own approval prompt once, and Darkbloom never uses sudo. --temporary adds a \
                link-local address alone, which lasts only until macOS next reconfigures the port. --remove \
                restores the network settings --fix changed. --dry-run prints the exact commands an approval \
                would run, and runs nothing.
                """)
        @Flag(help: "Print JSON instead of text; with --watch, one object per line.") var json = false
        @Flag(help: "Isolate the active Thunderbolt port: its own network service with a fixed address, outside every bridge, after approval in a macOS prompt.")
        var fix = false
        @Flag(help: "Restore the network settings an earlier --fix changed, after approval in a macOS prompt.") var remove = false
        @Flag(help: "Poll the link and print each change until interrupted.") var watch = false
        @Option(help: "With --fix or --remove: the RDMA device to act on, such as rdma_en6.") var device: String?
        @Flag(help: "With --fix: add a link-local address alone, which lasts until macOS next reconfigures the port.") var temporary = false
        @Flag(name: .customLong("dry-run"), help: "With --fix or --remove: print the commands an approval would run, and change nothing.")
        var dryRun = false

        func validate() throws {
            guard [fix, remove, watch].filter({ $0 }).count <= 1 else {
                throw ValidationError("Choose at most one of --fix, --remove and --watch.")
            }
            guard fix || !temporary else { throw ValidationError("--temporary applies only to --fix.") }
            guard fix || remove || !dryRun else { throw ValidationError("--dry-run applies only to --fix and --remove.") }
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
            let device = device, removing = remove, dryRun = dryRun
            let mode = temporary ? ClusterLinkRepair.Mode.temporary : .durable
            // Blocks while the person at the screen answers the macOS prompt; a dry run asks nothing.
            let result = await Task.detached {
                removing ? ClusterLinkRepair.remove(device: device, dryRun: dryRun)
                    : ClusterLinkRepair.fix(device: device, mode: mode, dryRun: dryRun)
            }.value
            if json { try printJSON(result) } else { for line in result.summaryLines { print(line) } }
            // Outside a dry run this is the only place the address is shown:
            // where no prompt could be, as commands for an administrator, on
            // standard error and never in JSON. The message that announces
            // them goes out first, also on a shared pipe.
            if !result.manualCommands.isEmpty {
                fflush(stdout)
                for command in result.manualCommands { printError(command) }
            }
            if result.outcome.exitCode != 0 { throw ExitCode(result.outcome.exitCode) }
        }
    }
}
