import Foundation
import ArgumentParser
import ProviderCore

extension Cluster {
    /// Registered by adding `Reap.self` to `Cluster.configuration.subcommands`.
    struct Reap: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "reap",
            abstract: "End and remove what a dead cluster session left on this Mac (orphaned workers and owners, a stranded device journal, stale bootstrap directories), and report it.", shouldDisplay: false)
        @Flag(help: "Print the report as JSON.") var json = false
        @Flag(name: .customLong("no-wait"), help: "Do not wait for a leftover's own contract before signalling it.") var noWait = false

        mutating func run() throws {
            let report = try ClusterOrphanSweep.reap(waitForContract: !noWait)
            if json { try printJSON(report) } else {
                print(ClusterOrphanSweep.summary(report) ?? "orphan sweep: nothing of a dead session was found")
                print("device journal: \(report.journal); kept: \(report.kept.map { "\($0.role.rawValue) \($0.processIdentifier) (\($0.reason))" }.joined(separator: ", "))")
            }
            if !report.clean { throw ExitCode.failure }
        }
    }

    /// Registered by adding `VerifyTeardown.self` to `Cluster.configuration.subcommands`.
    struct VerifyTeardown: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "verify-teardown",
            abstract: "After a stop: check that no cluster process, wired memory, device journal or bootstrap directory is left on this Mac, and report it.", shouldDisplay: false)
        @Flag(help: "Print the report as JSON.") var json = false
        @Option(name: .customLong("baseline-wired-bytes"), help: "Wired memory before the session started; the idle baseline when absent.")
        var baselineWiredBytes: UInt64?
        @Option(help: "Wired-memory samples, one per second.") var samples: Int = 5

        func validate() throws {
            guard (1...60).contains(samples) else { throw ValidationError("samples must be 1...60") }
        }

        mutating func run() throws {
            let report = try ClusterOrphanSweep.verify(baselineWiredBytes: baselineWiredBytes, samples: samples)
            if json { try printJSON(report) } else {
                print(report.passed ? "teardown verified: nothing left on this Mac" : "teardown NOT clean: " + report.reasons.joined(separator: "; "))
                if let wired = report.wired {
                    print("wired memory: lowest sample \(wired.samples.min()! >> 20) MiB, baseline \(wired.baselineBytes >> 20) MiB (\(wired.baseline)), tolerance \(wired.toleranceBytes >> 20) MiB")
                }
                print("device journal: \(report.journal)")
                if !report.otherClusters.isEmpty {
                    print("not counted: \(report.otherClusters.count) cluster process(es) of another cluster home (another identity's or install's, or a check's)")
                }
            }
            if !report.passed { throw ExitCode.failure }
        }
    }

    /// Registered by adding `CancelAll.self` to `Cluster.configuration.subcommands`.
    struct CancelAll: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "cancel-all",
            abstract: "Force-cancel every cluster request served on this Mac (each owner fences its worker at the protocol's own boundary; the pair re-forms). No SSH, no leader needed.", shouldDisplay: false)
        @Flag(help: "Print the report as JSON.") var json = false

        mutating func run() throws {
            let report = ClusterOrphanSweep.cancelAll()
            if json { try printJSON(report) } else {
                print("owners \(report.owners), workers \(report.workers); signalled \(report.signalled)")
            }
        }
    }
}
