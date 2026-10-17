import Foundation
import ArgumentParser
import ProviderCore

extension Cluster {
    /// The durable incident log (PROD-PLAN S24): `~/.darkbloom/cluster/incidents.json`.
    struct Incidents: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "incidents",
            abstract: "Show this Mac's cluster incidents with their guidance, or dismiss one.", shouldDisplay: false)
        @Option(help: "Show only incidents after this sequence number (the cursor a reader keeps).")
        var since: UInt64 = 0
        @Flag(help: "Include dismissed and superseded incidents.") var all = false
        @Option(help: "Mark the incident with this ID as dismissed (it is kept, flagged).") var dismiss: String?
        @Flag(help: "Print the feed as JSON (the oMLX incident schema plus reason codes).") var json = false

        mutating func run() throws {
            Darkbloom.ensureLogging()
            let observability = ClusterObservability.current()
            if let dismiss {
                guard try observability.dismissIncident(id: dismiss) else {
                    throw ValidationError("No incident has the ID \(dismiss).")
                }
                print("Dismissed \(dismiss).")
                return
            }
            if json { print(try observability.incidentFeedJSON(since: since)); return }
            for line in observability.incidentLines(since: since, includeClosed: all) { print(line) }
        }
    }
}
