import Foundation
import ArgumentParser
import ProviderCore

extension Cluster {
    /// Registered by adding `Recover.self` to `Cluster.configuration.subcommands`.
    struct Recover: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "recover",
            abstract: "Clear this Mac's cluster device journal after proving that nothing it names is still running.")
        @Flag(help: "Print the outcome and what was inspected as JSON.") var json = false

        mutating func run() throws {
            // Local inspection only: no saved setup, peer, model or network is used.
            let report = try ClusterDeviceRecovery.recover()
            if json { try printJSON(report) } else {
                print("Device journal: \(report.outcome.rawValue)")
                if let record = report.record {
                    print("Recorded session: cluster \(record.clusterID) · member \(record.peerID) rank \(record.rank) · epoch \(record.membershipEpoch)")
                }
                print(report.detail)
            }
            if !report.journalEmpty { throw ExitCode.failure }
        }
    }
}
