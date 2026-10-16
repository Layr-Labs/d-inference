import Darwin
import Foundation
import DarkbloomClusterProcess
import DarkbloomClusterProtocol

/// Finds and ends what a dead session left on this Mac, and says what it did.
///
/// The owner's reapers (oMLX `launch.py` `reap_orphaned_launches`: a launch
/// whose coordinator is gone has its ranks swept by their recorded pids;
/// ThunderMLX `auto_restart.sh` `cleanup_leftover_ranks`: SIGTERM every
/// leftover rank, verify, escalate to SIGKILL only in the hard mode) ported to
/// Darkbloom's process model, where every rank is a direct child of an owner
/// and every owner a direct child of the member or leader process:
///
/// - A `darkbloom-cluster-worker` or `cluster worker-owner` process whose
///   parent is gone (the kernel reparented it) belongs to a session that died
///   first. Its own contract ends it: a worker on lost input through its
///   forced exit, an owner at its child's retirement ceiling. The reaper waits
///   for that contract (`contractGraceNanoseconds`: the rank lease plus the
///   longest owner allowance plus the dead-man) and only then sends SIGTERM,
///   and SIGKILL only to a process that ignored SIGTERM for the longest kill
///   margin an owner grants (120 s) — never earlier, because a SIGKILL cannot
///   unwire.
/// - A process whose parent is alive is never touched: its owner handles it.
/// - A membership epoch the caller names as live (a session this process
///   still holds) is never touched either, whatever its parent.
/// - A stranded device journal is cleared through the existing recovery,
///   which first proves nothing it names is running.
/// - Bootstrap listener directories whose socket no process of this user has
///   bound are removed. The check reads the kernel's descriptor tables and
///   never connects: a connect would be accepted by a live listener in place
///   of the child it waits for and fail that launch.
/// - Cache staging roots (supplied by the caching tier) lose every entry
///   named by an epoch that is not live, once it is older than the grace.
///
/// Every decision is pure and testable (`plan`); the sweep takes its process
/// table, signals, clock and sleeps from the caller so a check can drive it
/// with a fake table and real orphaned children alike.
public enum ClusterOrphanReaper {
    public static let workerExecutableName = "darkbloom-cluster-worker"
    public static let bootstrapDirectoryPrefix = "/private/tmp/darkbloom-bootstrap-"

    /// How long a leftover may still be unwinding by its own contract before
    /// the reaper signals it: the rank lease it may still hold, the longest
    /// time its owner waits for it (SIGTERM and SIGKILL margins), and the
    /// forced exit's dead-man with its one extension (a release whose writes
    /// progress may run twice the bound). Derived from the protocol's bounds,
    /// never from a Mac or a model. The contract starts when the leftover's
    /// parent died, not when it started (see `sweepProcesses`).
    public static let contractGraceNanoseconds: UInt64 = ClusterWorkerLease.ttlNanoseconds
        + ClusterWorkerSignalPolicy.maximumAllowanceNanoseconds + ClusterForcedExitBounds.longestNanoseconds()

    public enum Role: String, Encodable, Sendable { case worker, owner }

    public struct Candidate: Equatable, Sendable, Encodable {
        public let processIdentifier: Int32
        public let role: Role
        public let membershipEpoch: String?
        public let startedAt: Double?
        /// Why it is a candidate.
        public let reason: String
    }

    public struct Kept: Equatable, Sendable, Encodable {
        public let processIdentifier: Int32
        public let role: Role
        public let reason: String
    }

    public struct Plan: Equatable, Sendable, Encodable {
        public let candidates: [Candidate]
        public let kept: [Kept]
    }

    /// The cluster processes this user runs, and which of them are orphans.
    /// `liveEpochs`: membership epochs of sessions the caller still holds.
    /// `protectedProcessIdentifiers`: the caller, its ancestors and children.
    public static func plan(processes: [ClusterProcessTable.Entry], liveEpochs: Set<String>,
                            protectedProcessIdentifiers: Set<Int32>) -> Plan {
        var candidates: [Candidate] = [], kept: [Kept] = []
        for entry in processes {
            guard let role = role(of: entry) else { continue }
            let epoch = membershipEpoch(of: entry)
            if protectedProcessIdentifiers.contains(entry.processIdentifier) {
                kept.append(.init(processIdentifier: entry.processIdentifier, role: role, reason: "this process or one it owns")); continue
            }
            if let epoch, liveEpochs.contains(epoch) {
                kept.append(.init(processIdentifier: entry.processIdentifier, role: role, reason: "membership epoch is live")); continue
            }
            guard let parent = entry.parentProcessIdentifier else {
                kept.append(.init(processIdentifier: entry.processIdentifier, role: role, reason: "parent unknown")); continue
            }
            guard parent <= 1 || !processes.contains(where: { $0.processIdentifier == parent }) && !ClusterProcessTable.isAlive(parent) else {
                kept.append(.init(processIdentifier: entry.processIdentifier, role: role, reason: "parent \(parent) is alive")); continue
            }
            candidates.append(.init(processIdentifier: entry.processIdentifier, role: role, membershipEpoch: epoch,
                startedAt: entry.startedAt, reason: "parent is gone"))
        }
        return .init(candidates: candidates.sorted { $0.processIdentifier < $1.processIdentifier },
                     kept: kept.sorted { $0.processIdentifier < $1.processIdentifier })
    }

    /// A worker is the worker executable; an owner is `darkbloom cluster
    /// worker-owner`. Anything else is not a cluster process.
    public static func role(of entry: ClusterProcessTable.Entry) -> Role? {
        let name = entry.executableName ?? entry.arguments.first.flatMap { $0.split(separator: "/").last.map(String.init) }
        if name == workerExecutableName { return .worker }
        if name == "darkbloom", entry.arguments.count >= 3, entry.arguments[1] == "cluster", entry.arguments[2] == "worker-owner" { return .owner }
        return nil
    }

    /// The `--membership-epoch` a worker was started with; owners carry none.
    public static func membershipEpoch(of entry: ClusterProcessTable.Entry) -> String? {
        guard let index = entry.arguments.firstIndex(of: "--membership-epoch"), index + 1 < entry.arguments.count,
              let uuid = UUID(uuidString: entry.arguments[index + 1]) else { return nil }
        return uuid.uuidString.lowercased()
    }

    // MARK: Force-cancel

    /// What `darkbloom cluster cancel-all` does with each cluster process.
    public struct CancelTargets: Equatable, Sendable {
        public let owners: [Int32]
        public let workers: [Int32]
        /// Owners to send SIGUSR1: those running this very image.
        public let signal: [Int32]
    }

    /// The owners of this Mac outside `protectedProcessIdentifiers`, and the
    /// ones among them whose running image is `ownImage` (the kernel's path of
    /// each process's executable, `image`). Only such an owner carries the
    /// force-cancel hook for certain; any other dies of SIGUSR1, so it is
    /// listed and never signalled. The first argument is not compared: an
    /// owner is launched by absolute path, a person types `darkbloom`.
    public static func cancelTargets(processes: [ClusterProcessTable.Entry], ownImage: String?,
                                     protectedProcessIdentifiers: Set<Int32>,
                                     image: (Int32) -> String? = { ClusterProcessTable.executablePath(of: $0) }) -> CancelTargets {
        var owners: [Int32] = [], workers: [Int32] = [], signal: [Int32] = []
        for entry in processes where !protectedProcessIdentifiers.contains(entry.processIdentifier) {
            switch role(of: entry) {
            case .owner:
                owners.append(entry.processIdentifier)
                if let ownImage, image(entry.processIdentifier) == ownImage { signal.append(entry.processIdentifier) }
            case .worker: workers.append(entry.processIdentifier)
            case nil: break
            }
        }
        return .init(owners: owners.sorted(), workers: workers.sorted(), signal: signal.sorted())
    }

    // MARK: Sweep

    public enum ProcessOutcome: String, Encodable, Sendable {
        /// Ended by its own contract while the reaper waited.
        case endedByItself
        case endedAfterTerm
        case endedAfterKill
        /// Still running after SIGKILL and the reap margin; reported, never hidden.
        case survived
        /// The process number now belongs to another process (its start time
        /// differs from the planned one): the orphan is gone, and nothing more
        /// is ever sent to that number.
        case replaced
        /// The candidate's start time was unknown when it was planned, so its
        /// identity cannot be checked before a signal: nothing is sent, and
        /// the sweep is not clean.
        case unverified
    }

    public struct ProcessResult: Equatable, Sendable, Encodable {
        public let candidate: Candidate
        public let outcome: ProcessOutcome
        public let waitedNanoseconds: UInt64
    }

    public struct Report: Encodable, Sendable {
        public let schema = "darkbloom_cluster_reap_v1"
        public let at: Double
        public let processes: [ProcessResult]
        public let kept: [Kept]
        public let journal: String
        public let bootstrapDirectoriesRemoved: [String]
        public let stagingEntriesRemoved: [String]
        public let errors: [String]
        /// True when nothing of a dead session is left after the sweep.
        public let clean: Bool
        public init(at: Double, processes: [ProcessResult], kept: [Kept], journal: String,
                    bootstrapDirectoriesRemoved: [String], stagingEntriesRemoved: [String], errors: [String]) {
            self.at = at; self.processes = processes; self.kept = kept; self.journal = journal
            self.bootstrapDirectoriesRemoved = bootstrapDirectoriesRemoved; self.stagingEntriesRemoved = stagingEntriesRemoved
            self.errors = errors
            clean = processes.allSatisfy { $0.outcome != .survived && $0.outcome != .unverified } && errors.isEmpty
                && journal != "refusedLiveWorker"
        }
    }

    /// Hooks the sweep acts through; production uses the real ones.
    public struct Actions: Sendable {
        public var isAlive: @Sendable (Int32) -> Bool = { ClusterProcessTable.isAlive($0) }
        /// The start time of the process now holding the number; nil when none.
        public var startTime: @Sendable (Int32) -> Double? = { ClusterProcessTable.startTime(of: $0) }
        public var signal: @Sendable (Int32, Int32) -> Void = { _ = Darwin.kill($0, $1) }
        public var now: @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
        public var sleep: @Sendable (UInt64) -> Void = { nanoseconds in
            var nap = timespec(tv_sec: Int(nanoseconds / 1_000_000_000), tv_nsec: Int(nanoseconds % 1_000_000_000))
            nanosleep(&nap, nil)
        }
        public var wallClock: @Sendable () -> Double = { Date().timeIntervalSince1970 }
        public init() {}
    }

    public struct Limits: Sendable {
        /// Wait for a leftover's own contract before SIGTERM.
        public var contractGraceNanoseconds: UInt64 = ClusterOrphanReaper.contractGraceNanoseconds
        /// SIGTERM to SIGKILL: the longest margin any owner grants a loaded
        /// rank (its planned bytes are unknown here, so the ceiling applies:
        /// a SIGKILL before a rank has released is what strands wired memory).
        public var killMarginNanoseconds: UInt64 = ClusterWorkerSignalPolicy.maximumKillMarginNanoseconds
        /// After SIGKILL, before giving up on the exit.
        public var reapMarginNanoseconds: UInt64 = ClusterWorkerSignalPolicy.standard.reapMarginNanoseconds
        public var pollNanoseconds: UInt64 = 200_000_000
        public init() {}
    }

    /// Ends every candidate of `plan` as the contract allows and returns what
    /// happened to each. `startedAt` is wall-clock seconds and is the
    /// candidate's identity only, never its age: a worker that served for an
    /// hour and lost its owner a moment ago is starting its contract now.
    /// The kernel keeps no time of a reparenting, and the parent died at the
    /// latest when the sweep saw the orphan, so the grace runs from the
    /// sweep's start, once for all candidates (handling them one after the
    /// other never stretches it). Before every
    /// signal the number must still hold the planned process (same start
    /// time; oMLX `_sweep_rank_processes`: "identity changed; refusing to
    /// signal a reused PID"): the wait before a signal can be minutes, long
    /// enough for the number to be reused by an unrelated process. A
    /// candidate whose start is unknown is never signalled.
    public static func sweepProcesses(_ plan: Plan, limits: Limits = .init(), actions: Actions = .init()) -> [ProcessResult] {
        var results: [ProcessResult] = []
        let graceSum = actions.now().addingReportingOverflow(limits.contractGraceNanoseconds)
        let graceEnd = graceSum.overflow ? UInt64.max : graceSum.partialValue
        for candidate in plan.candidates {
            let begin = actions.now()
            let remainingGrace = graceEnd > begin ? graceEnd - begin : 0
            guard let planned = candidate.startedAt else {
                results.append(.init(candidate: candidate, outcome: .unverified, waitedNanoseconds: 0)); continue
            }
            /// Whether the number still holds the planned process.
            enum Presence { case same, gone, replaced }
            func presence() -> Presence {
                guard let started = actions.startTime(candidate.processIdentifier) else { return .gone }
                return abs(started - planned) < 0.001 ? .same : .replaced
            }
            /// Waits at most `bound` for the planned process to leave the number.
            func wait(_ bound: UInt64) -> Presence {
                let end = actions.now() &+ bound
                while true {
                    let state = presence()
                    if state != .same || actions.now() >= end { return state }
                    actions.sleep(min(limits.pollNanoseconds, max(1, end &- actions.now())))
                }
            }
            /// Sends `signal` only to the planned process; the presence it found.
            func send(_ signal: Int32) -> Presence {
                let state = presence()
                if state == .same { actions.signal(candidate.processIdentifier, signal) }
                return state
            }
            let outcome: ProcessOutcome
            switch wait(remainingGrace) {
            case .gone: outcome = .endedByItself
            case .replaced: outcome = .replaced
            case .same:
                switch send(SIGTERM) {
                case .gone: outcome = .endedByItself
                case .replaced: outcome = .replaced
                case .same:
                    switch wait(limits.killMarginNanoseconds) {
                    case .gone: outcome = .endedAfterTerm
                    case .replaced: outcome = .replaced
                    case .same:
                        switch send(SIGKILL) {
                        case .gone: outcome = .endedAfterTerm
                        case .replaced: outcome = .replaced
                        case .same:
                            switch wait(limits.reapMarginNanoseconds) {
                            case .gone: outcome = .endedAfterKill
                            case .replaced: outcome = .replaced
                            case .same: outcome = .survived
                            }
                        }
                    }
                }
            }
            results.append(.init(candidate: candidate, outcome: outcome, waitedNanoseconds: actions.now() &- begin))
        }
        return results
    }

    /// Bootstrap listener directories of this user whose socket no process
    /// of this user has bound. The kernel's descriptor tables decide; nothing
    /// connects: a connect would be accepted by a live listener in place of
    /// the child it waits for, and the listener (which checks its peer) would
    /// then fail that launch. A directory younger than `minimumAgeSeconds` is
    /// never stale: its listener may be between creating it and binding.
    public static func staleBootstrapDirectories(under root: String = "/private/tmp", minimumAgeSeconds: Double = 2,
                                                 boundPaths: [String: Int32]? = nil,
                                                 now: Double = Date().timeIntervalSince1970) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        let prefix = String(bootstrapDirectoryPrefix.split(separator: "/").last!)
        let bound = boundPaths ?? ClusterProcessTable.boundUnixSocketPaths()
        // No bound socket at all means the tables could not be read: then
        // nothing is called stale (a live listener's directory is never removed
        // on a guess).
        guard boundPaths != nil || !bound.isEmpty else { return [] }
        var stale: [String] = []
        for name in names.sorted() where name.hasPrefix(prefix) {
            let directory = root + "/" + name
            var information = stat()
            guard lstat(directory, &information) == 0, information.st_mode & S_IFMT == S_IFDIR,
                  information.st_uid == geteuid() else { continue }
            let created = Double(information.st_ctimespec.tv_sec) + Double(information.st_ctimespec.tv_nsec) / 1e9
            guard now - created >= minimumAgeSeconds else { continue }
            if bound[directory + "/channel"] == nil { stale.append(directory) }
        }
        return stale
    }

    /// Removes a stale bootstrap directory (its socket file and the directory
    /// itself, nothing else). Returns false when something unexpected is inside.
    public static func removeBootstrapDirectory(_ directory: String) -> Bool {
        guard directory.hasPrefix(bootstrapDirectoryPrefix) else { return false }
        unlink(directory + "/channel")
        return rmdir(directory) == 0
    }

    /// The membership epochs running cluster workers were started with,
    /// whatever their parent: a session whose worker still runs (serving, or
    /// an orphan still unwinding) owns its staging directory.
    public static func runningWorkerEpochs(_ processes: [ClusterProcessTable.Entry]) -> Set<String> {
        Set(processes.compactMap { role(of: $0) == .worker ? membershipEpoch(of: $0) : nil })
    }

    /// Entries of a cache staging root named by a membership epoch that is
    /// not live and whose directory is older than the grace. Only such entries
    /// are ever removed; everything else in the root is left alone. An epoch
    /// is live when the caller names it or a running worker holds it
    /// (`runningWorkers`, the process table read after the process sweep):
    /// the callers name none, and a serving session's epoch directory keeps
    /// the mtime of its first record (its writes land in `rank<r>` below it),
    /// so its age alone says nothing.
    public static func staleStagingEntries(roots: [URL], liveEpochs: Set<String>, graceSeconds: Double,
                                           now: Double = Date().timeIntervalSince1970,
                                           runningWorkers: [ClusterProcessTable.Entry] = []) -> [URL] {
        let live = liveEpochs.union(runningWorkerEpochs(runningWorkers))
        var stale: [URL] = []
        for root in roots {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { continue }
            for name in names.sorted() {
                guard let uuid = UUID(uuidString: name), uuid.uuidString.lowercased() == name, !live.contains(name) else { continue }
                let entry = root.appendingPathComponent(name, isDirectory: true)
                var information = stat()
                guard lstat(entry.path, &information) == 0, information.st_mode & S_IFMT == S_IFDIR,
                      information.st_uid == geteuid() else { continue }
                let modified = Double(information.st_mtimespec.tv_sec) + Double(information.st_mtimespec.tv_nsec) / 1e9
                if now - modified >= graceSeconds { stale.append(entry) }
            }
        }
        return stale
    }

    /// The whole sweep on this Mac. `deviceDirectory` is the device journal's
    /// directory; `stagingRoots` the caching tier's roots (none at d88ba3ee6).
    public static func sweep(liveEpochs: Set<String>, deviceDirectory: URL?, stagingRoots: [URL] = [],
                             limits: Limits = .init(), actions: Actions = .init()) -> Report {
        let plan = Self.plan(processes: ClusterProcessTable.running(), liveEpochs: liveEpochs,
                             protectedProcessIdentifiers: Self.ownLineage())
        let processes = sweepProcesses(plan, limits: limits, actions: actions)
        var errors: [String] = []
        var journal = "notInspected"
        if let deviceDirectory {
            do {
                switch try ClusterDeviceLeaseRecovery.recover(directoryURL: deviceDirectory) {
                case .nothingToRecover: journal = "nothingToRecover"
                case .cleared: journal = "cleared"
                case .refusedLiveOwner: journal = "refusedLiveOwner"
                case .refusedLiveWorker: journal = "refusedLiveWorker"
                case .refusedUnreadable: journal = "refusedUnreadable"
                }
            } catch { errors.append("journal: \(error)") }
        }
        var removedDirectories: [String] = []
        for directory in staleBootstrapDirectories() {
            if removeBootstrapDirectory(directory) { removedDirectories.append(directory) }
            else { errors.append("bootstrap directory not removed: \(directory)") }
        }
        var removedStaging: [String] = []
        // Read again after the process sweep: what still runs keeps its staging.
        let stillRunning = stagingRoots.isEmpty ? [] : ClusterProcessTable.running()
        for entry in staleStagingEntries(roots: stagingRoots, liveEpochs: liveEpochs,
                                         graceSeconds: Double(limits.contractGraceNanoseconds) / 1e9,
                                         runningWorkers: stillRunning) {
            do { try FileManager.default.removeItem(at: entry); removedStaging.append(entry.path) }
            catch { errors.append("staging entry not removed: \(entry.lastPathComponent)") }
        }
        return .init(at: actions.wallClock(), processes: processes, kept: plan.kept, journal: journal,
                     bootstrapDirectoriesRemoved: removedDirectories, stagingEntriesRemoved: removedStaging, errors: errors)
    }

    /// This process, its ancestors and its direct children: never reaped.
    public static func ownLineage() -> Set<Int32> {
        var result: Set<Int32> = [getpid()]
        var current = getpid()
        while current > 1, let parent = ClusterProcessTable.parentProcessIdentifier(of: current) {
            guard parent > 1, result.insert(parent).inserted else { break }
            current = parent
        }
        for entry in ClusterProcessTable.running() where entry.parentProcessIdentifier == getpid() {
            result.insert(entry.processIdentifier)
        }
        return result
    }
}
