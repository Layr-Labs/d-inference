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
    /// The pair's SSD-tier staging directories (half-written prompt-prefix
    /// records, one directory per membership epoch) are swept with the rest:
    /// a dead session's go, a live session's (`liveEpochs`) never.
    public static func reap(liveEpochs: Set<String> = [], waitForContract: Bool = true,
                            stagingRoots: [URL]? = nil) throws -> ClusterOrphanReaper.Report {
        let paths = try ClusterUserPaths()
        var limits = ClusterOrphanReaper.Limits()
        if !waitForContract { limits.contractGraceNanoseconds = 0 }
        return ClusterOrphanReaper.sweep(liveEpochs: liveEpochs, deviceDirectory: paths.deviceDirectory,
                                         stagingRoots: stagingRoots ?? cacheStagingRoots(), limits: limits)
    }

    /// The staging roots of the pair's SSD tier on this Mac: under the root the
    /// saved cache settings choose (`darkbloom cache set --directory`) and
    /// under the built-in one, once each. Never fails: an unreadable
    /// configuration leaves the built-in root.
    public static func cacheStagingRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                         providerConfiguration: URL? = try? ConfigManager.defaultConfigPath()) -> [URL] {
        var roots: [URL] = []
        if let providerConfiguration,
           let settings = try? ClusterPrefixCacheSettings.resolved(providerConfiguration: providerConfiguration) {
            roots.append(settings.root)
        }
        roots.append(ClusterPrefixCacheSettings.defaultRoot(home: home))
        var seen = Set<String>()
        return roots.map { ClusterPrefixCacheSettings.stagingRoot(root: $0) }
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
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

    /// Counts only THIS cluster's processes (`scope()`): another cluster home's or a check's processes of the same user
    /// are listed apart and never fail it; with no pairing every cluster process counts.
    public static func verify(liveEpochs: Set<String> = [], baselineWiredBytes: UInt64? = nil, samples: Int = 5,
                              intervalNanoseconds: UInt64 = 1_000_000_000) throws -> ClusterTeardownVerification.Report {
        let paths = try ClusterUserPaths()
        return ClusterTeardownVerification.verify(liveEpochs: liveEpochs, deviceDirectory: paths.deviceDirectory,
            baselineWiredBytes: baselineWiredBytes, samples: samples, intervalNanoseconds: intervalNanoseconds, scope: scope())
    }

    /// This cluster on this Mac: the paired member identity its workers carry, and this install's owner executable.
    public static func scope(memberID: String? = (try? ClusterSetupLinkExchange.pairing())?.localMemberID,
                             executablePath: String = ClusterProcessTable.executablePath(of: getpid()) ?? "") -> ClusterTeardownVerification.Scope {
        var executables: Set<String> = []
        for path in [executablePath, ClusterProcessTable.executablePath(of: getpid())].compactMap({ $0 }) where !path.isEmpty {
            executables.insert(path)
            executables.insert(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        }
        return .init(memberID: memberID, ownerExecutables: executables)
    }

    public struct CancelAllReport: Encodable, Sendable {
        public let schema = "darkbloom_cluster_cancel_all_v1"
        public let owners: [Int32]
        public let workers: [Int32]
        public let signalled: [Int32]
    }

    /// SIGUSR1 to every owner running THIS darkbloom binary (each fences its
    /// worker: the protocol's own drain, locally triggered). The kernel's path
    /// of each owner's image is compared with this process's, never the first
    /// argument (an owner is launched by absolute path; a person types
    /// `darkbloom`). An owner of another install does not carry the hook, and a
    /// process without a handler dies of SIGUSR1, so it is listed and never
    /// signalled; workers are fenced by their owners, never signalled here (an
    /// orphaned worker is the reaper's). Never SIGTERM, never SIGKILL.
    public static func cancelAll(ownImage: String? = ClusterProcessTable.executablePath(of: getpid())) -> CancelAllReport {
        let targets = ClusterOrphanReaper.cancelTargets(processes: ClusterProcessTable.running(), ownImage: ownImage,
                                                        protectedProcessIdentifiers: ClusterOrphanReaper.ownLineage())
        let signalled = targets.signal.filter { Darwin.kill($0, SIGUSR1) == 0 }
        return .init(owners: targets.owners, workers: targets.workers, signalled: signalled)
    }
}
