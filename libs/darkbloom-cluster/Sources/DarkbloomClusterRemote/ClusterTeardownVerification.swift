import Darwin
import Foundation
import DarkbloomClusterProcess

/// After a stop: a machine-checkable statement that nothing is left on this Mac.
///
/// The owner's verified teardown (oMLX 8062c7b1 ring verified-teardown tests:
/// the kill is verified and survivors raise; ThunderMLX `stop_cluster.sh`:
/// rank processes counted on both Macs, then wired memory on both compared with
/// a limit and "ORPHANED METAL MEMORY DETECTED" or "Memory recovered cleanly"
/// printed) as one report a product command prints and a harness or a
/// supervisor can read. Each check names what it found; `passed` is the
/// conjunction. Every bound is derived: the wired-memory tolerance from the
/// Mac's physical memory, the idle baseline from the orphan-wired guard.
///
/// What this cannot see and says so: RDMA registrations and queue pairs are
/// kernel objects a user process cannot enumerate; they end with the process
/// that made them, so the process check and the wired-memory check are their
/// evidence here, and the rank's own JACCL teardown line is the direct one.
public enum ClusterTeardownVerification {
    public struct ProcessFinding: Encodable, Equatable, Sendable {
        public let processIdentifier: Int32
        public let role: String
        public let membershipEpoch: String?
        public let parentProcessIdentifier: Int32?
    }

    public struct WiredFinding: Encodable, Equatable, Sendable {
        /// Samples in order, bytes.
        public let samples: [UInt64]
        public let baselineBytes: UInt64
        public let toleranceBytes: UInt64
        /// Lowest sample minus the baseline, or 0 when below it.
        public let excessBytes: UInt64
        public let withinTolerance: Bool
        /// How the baseline was chosen: "given" or "idle".
        public let baseline: String
    }

    public struct Report: Encodable, Sendable {
        public let schema = "darkbloom_cluster_teardown_verification_v1"
        public let at: Double
        public let processes: [ProcessFinding]
        /// Cluster processes of this user that belong to ANOTHER cluster home (another identity's workers, another
        /// install's owners, a check's fake workers): listed, never counted against this cluster's teardown.
        public var otherClusters: [ProcessFinding] = []
        public let wired: WiredFinding?
        /// absentOrEmpty, heldByLiveOwner, stranded, unreadable, notInspected or error:...
        public let journal: String
        public let staleBootstrapDirectories: [String]
        public let rdma: String
        public let reasons: [String]
        public let passed: Bool
    }

    /// Tolerance for wired memory above the baseline after a stop: the larger
    /// of 1 GiB and 1/128 of physical memory (2 GiB on a 256 GiB Mac).
    public static func toleranceBytes(physicalBytes: UInt64) -> UInt64 {
        max(1 << 30, physicalBytes / 128)
    }

    /// Pure decision over sampled values: the lowest sample is what counts
    /// (wired memory falls after an exit and the samples are taken while it
    /// settles); the latest is reported with it.
    public static func wiredFinding(samples: [UInt64], baselineBytes: UInt64?, physicalBytes: UInt64) -> WiredFinding? {
        guard let lowest = samples.min() else { return nil }
        let baseline = baselineBytes ?? ClusterOrphanWiredGuard.idleBaselineBytes(physicalBytes: physicalBytes)
        let tolerance = toleranceBytes(physicalBytes: physicalBytes)
        let excess = lowest > baseline ? lowest - baseline : 0
        return .init(samples: samples, baselineBytes: baseline, toleranceBytes: tolerance, excessBytes: excess,
                     withinTolerance: excess <= tolerance, baseline: baselineBytes == nil ? "idle" : "given")
    }

    /// Which cluster processes are THIS cluster's: its workers carry this Mac's member identity among their peers
    /// (every installed-session worker is started with `--peer0-id`/`--peer1-id`), and its owners run this install's
    /// executable or own one of its workers. Anything else of this user (another identity's or another install's
    /// processes, a check's fake workers) is listed apart and never fails this cluster's teardown. With no identity
    /// known (no pairing) every cluster process counts, as before.
    public struct Scope: Sendable, Equatable {
        public var memberID: String?
        /// Full paths of this install's owner executable (the process table's spelling and the resolved file).
        public var ownerExecutables: Set<String>
        public init(memberID: String?, ownerExecutables: Set<String>) { self.memberID = memberID; self.ownerExecutables = ownerExecutables }

        public static func peerIDs(of entry: ClusterProcessTable.Entry) -> [String] {
            entry.arguments.indices.compactMap { index in
                ["--peer0-id", "--peer1-id"].contains(entry.arguments[index]) && index + 1 < entry.arguments.count ? entry.arguments[index + 1] : nil
            }
        }

        /// `executablePath`: the entry's executable file (nil when unreadable).
        public func includes(_ entry: ClusterProcessTable.Entry, among all: [ClusterProcessTable.Entry],
                             executablePath: (Int32) -> String?) -> Bool {
            guard let memberID else { return true }
            switch ClusterOrphanReaper.role(of: entry) {
            case .worker?: return Self.peerIDs(of: entry).contains(memberID)
            case .owner?:
                let paths = [executablePath(entry.processIdentifier), entry.arguments.first].compactMap { $0 }
                if paths.contains(where: ownerExecutables.contains) { return true }
                return all.contains { child in
                    child.parentProcessIdentifier == entry.processIdentifier && ClusterOrphanReaper.role(of: child) == .worker
                        && Self.peerIDs(of: child).contains(memberID)
                }
            case nil: return false
            }
        }
    }

    /// Pure assembly from what was observed. `scope` nil: every cluster process of this user counts.
    public static func report(at: Double, processes: [ClusterProcessTable.Entry], liveEpochs: Set<String>,
                              protectedProcessIdentifiers: Set<Int32>, wired: WiredFinding?, journal: String,
                              staleBootstrapDirectories: [String], scope: Scope? = nil,
                              executablePath: (Int32) -> String? = { ClusterProcessTable.executablePath(of: $0) }) -> Report {
        var findings: [ProcessFinding] = [], others: [ProcessFinding] = []
        for entry in processes {
            guard let role = ClusterOrphanReaper.role(of: entry), !protectedProcessIdentifiers.contains(entry.processIdentifier) else { continue }
            let epoch = ClusterOrphanReaper.membershipEpoch(of: entry)
            if let epoch, liveEpochs.contains(epoch) { continue }
            let finding = ProcessFinding(processIdentifier: entry.processIdentifier, role: role.rawValue, membershipEpoch: epoch,
                                         parentProcessIdentifier: entry.parentProcessIdentifier)
            if let scope, !scope.includes(entry, among: processes, executablePath: executablePath) { others.append(finding) } else { findings.append(finding) }
        }
        findings.sort { $0.processIdentifier < $1.processIdentifier }
        others.sort { $0.processIdentifier < $1.processIdentifier }
        var reasons: [String] = []
        if !findings.isEmpty { reasons.append("\(findings.count) cluster process(es) still running") }
        if let wired, !wired.withinTolerance {
            reasons.append("wired memory \(wired.excessBytes >> 20) MiB above its baseline (tolerance \(wired.toleranceBytes >> 20) MiB)")
        }
        if journal == "stranded" { reasons.append("device journal names a session whose owner is gone") }
        if journal == "heldByLiveOwner" && findings.isEmpty && liveEpochs.isEmpty { reasons.append("device journal is held by a live owner") }
        if journal == "unreadable" { reasons.append("device journal holds bytes this build did not write") }
        if journal.hasPrefix("error:") { reasons.append(journal) }
        if !staleBootstrapDirectories.isEmpty { reasons.append("\(staleBootstrapDirectories.count) stale bootstrap director(ies)") }
        var report = Report(at: at, processes: findings, wired: wired, journal: journal, staleBootstrapDirectories: staleBootstrapDirectories,
                            rdma: "not enumerable from a user process; ends with the rank process (see processes and wired)",
                            reasons: reasons, passed: reasons.isEmpty)
        report.otherClusters = others
        return report
    }

    /// The live verification on this Mac. `samples` wired-memory readings
    /// `intervalNanoseconds` apart; `baselineWiredBytes` the reading taken
    /// before the session started, or nil for the idle baseline.
    public static func verify(liveEpochs: Set<String> = [], deviceDirectory: URL?, baselineWiredBytes: UInt64? = nil,
                              samples: Int = 5, intervalNanoseconds: UInt64 = 1_000_000_000, scope: Scope? = nil) -> Report {
        var readings: [UInt64] = []
        for index in 0..<max(1, samples) {
            if index > 0 {
                var nap = timespec(tv_sec: Int(intervalNanoseconds / 1_000_000_000), tv_nsec: Int(intervalNanoseconds % 1_000_000_000))
                nanosleep(&nap, nil)
            }
            if let value = ClusterOrphanWiredGuard.wiredBytes() { readings.append(value) }
        }
        let wired = wiredFinding(samples: readings, baselineBytes: baselineWiredBytes,
                                 physicalBytes: ClusterOrphanWiredGuard.physicalBytes())
        var journal = "notInspected"
        if let deviceDirectory {
            do {
                switch try ClusterDeviceLeaseRecovery.inspect(directoryURL: deviceDirectory) {
                case .absentOrEmpty: journal = "absentOrEmpty"
                case .heldByLiveOwner: journal = "heldByLiveOwner"
                case .stranded: journal = "stranded"
                case .unreadable: journal = "unreadable"
                }
            } catch { journal = "error: \(error)" }
        }
        return report(at: Date().timeIntervalSince1970, processes: ClusterProcessTable.running(), liveEpochs: liveEpochs,
                      protectedProcessIdentifiers: ClusterOrphanReaper.ownLineage(), wired: wired, journal: journal,
                      staleBootstrapDirectories: ClusterOrphanReaper.staleBootstrapDirectories(), scope: scope)
    }
}
