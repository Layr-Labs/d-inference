import Foundation
import ArgumentParser
import ProviderCore

extension Cluster {
    struct Link: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "link",
            abstract: "Check this Mac's Thunderbolt RDMA link prerequisites without changing settings or contacting a peer.")
        @Flag(help: "Print the local link readiness report as JSON.") var json = false

        mutating func run() async throws {
            Darkbloom.ensureLogging()
            // Local RDMA and interface state only: no provider configuration,
            // hardware/model discovery, update banner, enrollment or connection.
            let report = await Task.detached { ClusterLinkReadinessProbe.inspectLocalLink() }.value
            if json { try printJSON(report) } else { for line in report.summaryLines { print(line) } }
            if report.state != .ready { throw ExitCode.failure }
        }
    }
}
