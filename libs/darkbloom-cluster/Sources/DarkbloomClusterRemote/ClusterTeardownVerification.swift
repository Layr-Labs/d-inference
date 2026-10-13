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

    /// Pure assembly from what was observed.
    public static func report(at: Double, processes: [ClusterProcessTable.Entry], liveEpochs: Set<String>,
                              protectedProcessIdentifiers: Set<Int32>, wired: WiredFinding?, journal: String,
                              staleBootstrapDirectories: [String]) -> Report {
        var findings: [ProcessFinding] = []
        for entry in processes {
            guard let role = ClusterOrphanReaper.role(of: entry), !protectedProcessIdentifiers.contains(entry.processIdentifier) else { continue }
            let epoch = ClusterOrphanReaper.membershipEpoch(of: entry)
            if let epoch, liveEpochs.contains(epoch) { continue }
            findings.append(.init(processIdentifier: entry.processIdentifier, role: role.rawValue, membershipEpoch: epoch,
                                  parentProcessIdentifier: entry.parentProcessIdentifier))
        }
        findings.sort { $0.processIdentifier < $1.processIdentifier }
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
        return .init(at: at, processes: findings, wired: wired, journal: journal, staleBootstrapDirectories: staleBootstrapDirectories,
                     rdma: "not enumerable from a user process; ends with the rank process (see processes and wired)",
                     reasons: reasons, passed: reasons.isEmpty)
    }

    /// The live verification on this Mac. `samples` wired-memory readings
    /// `intervalNanoseconds` apart; `baselineWiredBytes` the reading taken
    /// before the session started, or nil for the idle baseline.
    public static func verify(liveEpochs: Set<String> = [], deviceDirectory: URL?, baselineWiredBytes: UInt64? = nil,
                              samples: Int = 5, intervalNanoseconds: UInt64 = 1_000_000_000) -> Report {
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
                      staleBootstrapDirectories: ClusterOrphanReaper.staleBootstrapDirectories())
    }
}
