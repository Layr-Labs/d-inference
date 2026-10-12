import Darwin
import Foundation
import DarkbloomClusterProcess
import DarkbloomClusterRemote

/// The product's orphan sweep and teardown verification on this Mac, over
/// the user's canonical cluster paths: what `darkbloom cluster reap`,
/// `darkbloom cluster verify-teardown` and `darkbloom cluster cancel-all`
/// run, and what a member runs at its start and its end and a supervisor
/// before every restart. Local only: no saved setup, peer, model or network.
public enum ClusterOrphanSweep {
    /// Everything of a dead session is ended and removed; `liveEpochs` are
    /// sessions this process still holds (none for the commands).
    public static func reap(liveEpochs: Set<String> = [], waitForContract: Bool = true) throws -> ClusterOrphanReaper.Report {
        let paths = try ClusterUserPaths()
        var limits = ClusterOrphanReaper.Limits()
        if !waitForContract { limits.contractGraceNanoseconds = 0 }
        return ClusterOrphanReaper.sweep(liveEpochs: liveEpochs, deviceDirectory: paths.deviceDirectory, limits: limits)
    }

    /// One line for a member or supervisor log; nil when there was nothing
    /// to do (an empty sweep is the common case and stays quiet).
    public static func summary(_ report: ClusterOrphanReaper.Report) -> String? {
        if report.processes.isEmpty && report.bootstrapDirectoriesRemoved.isEmpty && report.stagingEntriesRemoved.isEmpty
            && report.errors.isEmpty && report.journal != "cleared" { return nil }
        var parts: [String] = []
        for result in report.processes {
            parts.append("\(result.candidate.role.rawValue) \(result.candidate.processIdentifier) \(result.outcome.rawValue) after \(result.waitedNanoseconds / 1_000_000) ms")
        }
        if report.journal == "cleared" { parts.append("device journal cleared") }
        if !report.bootstrapDirectoriesRemoved.isEmpty { parts.append("\(report.bootstrapDirectoriesRemoved.count) stale bootstrap director(ies) removed") }
        if !report.stagingEntriesRemoved.isEmpty { parts.append("\(report.stagingEntriesRemoved.count) stale cache staging entr(ies) removed") }
        parts.append(contentsOf: report.errors.map { "error: \($0)" })
        return "orphan sweep: " + parts.joined(separator: "; ")
    }

    public static func verify(liveEpochs: Set<String> = [], baselineWiredBytes: UInt64? = nil, samples: Int = 5,
                              intervalNanoseconds: UInt64 = 1_000_000_000) throws -> ClusterTeardownVerification.Report {
        let paths = try ClusterUserPaths()
        return ClusterTeardownVerification.verify(liveEpochs: liveEpochs, deviceDirectory: paths.deviceDirectory,
            baselineWiredBytes: baselineWiredBytes, samples: samples, intervalNanoseconds: intervalNanoseconds)
    }

    public struct CancelAllReport: Encodable, Sendable {
        public let schema = "darkbloom_cluster_cancel_all_v1"
        public let owners: [Int32]
        public let workers: [Int32]
        public let signalled: [Int32]
    }

    /// SIGUSR1 to every owner started from THIS darkbloom binary (each fences
    /// its worker: the protocol's own drain, locally triggered). An owner of
    /// another install does not carry the hook, and a process without a
    /// handler dies of SIGUSR1, so it is listed and never signalled; workers
    /// are fenced by their owners, never signalled here (an orphaned worker
    /// is the reaper's). Never SIGTERM, never SIGKILL.
    public static func cancelAll(executablePath: String = Self.currentExecutablePath()) -> CancelAllReport {
        let processes = ClusterProcessTable.running()
        let mine = ClusterOrphanReaper.ownLineage()
        var owners: [Int32] = [], workers: [Int32] = [], signalled: [Int32] = []
        for entry in processes where !mine.contains(entry.processIdentifier) {
            switch ClusterOrphanReaper.role(of: entry) {
            case .owner:
                owners.append(entry.processIdentifier)
                guard entry.arguments.first == executablePath else { continue }
                if Darwin.kill(entry.processIdentifier, SIGUSR1) == 0 { signalled.append(entry.processIdentifier) }
            case .worker: workers.append(entry.processIdentifier)
            case nil: break
            }
        }
        return .init(owners: owners.sorted(), workers: workers.sorted(), signalled: signalled.sorted())
    }

    /// This process's executable, as the process table spells it.
    public static func currentExecutablePath() -> String {
        ClusterProcessTable.arguments(of: getpid())?.first ?? Bundle.main.executablePath ?? ""
    }
}
