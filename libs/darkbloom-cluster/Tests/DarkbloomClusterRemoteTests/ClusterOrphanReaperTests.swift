import Darwin
import Foundation
import XCTest
import DarkbloomClusterProcess
import DarkbloomClusterProtocol
@testable import DarkbloomClusterRemote

/// The orphan reaper's decisions (pure, on a fake process table), its sweep
/// (fake signals and clock), and one real orphan: a copy of /bin/sh named as
/// the worker, started by a shell that exits first, so the kernel reparents
/// it. No model, no GPU, no network.
final class ClusterOrphanReaperTests: XCTestCase {
    private let epoch = UUID().uuidString.lowercased()
    private func worker(_ pid: Int32, parent: Int32?, epoch: String? = nil) -> ClusterProcessTable.Entry {
        var arguments = ["/opt/x/darkbloom-cluster-worker", "--model-dir", "/m", "--rank", "1"]
        if let epoch { arguments += ["--membership-epoch", epoch] }
        return .init(processIdentifier: pid, arguments: arguments, parentProcessIdentifier: parent,
                     executableName: "darkbloom-cluster-worker", startedAt: 1_000)
    }
    private func owner(_ pid: Int32, parent: Int32?) -> ClusterProcessTable.Entry {
        .init(processIdentifier: pid, arguments: ["/opt/x/darkbloom", "cluster", "worker-owner", "--stdio"],
              parentProcessIdentifier: parent, executableName: "darkbloom", startedAt: 1_000)
    }

    func testPlanKeepsLiveParentsLiveEpochsAndItsOwnLineage() {
        // Pids far above any real one; the "alive parent" is this test process.
        let me = getpid(), liveEpoch = UUID().uuidString.lowercased()
        let processes = [
            worker(900_001, parent: 1, epoch: epoch),            // parent gone -> candidate
            worker(900_002, parent: me, epoch: epoch),           // parent alive -> kept
            worker(900_003, parent: 1, epoch: liveEpoch),        // epoch live -> kept
            owner(900_004, parent: 1),                           // owner, parent gone -> candidate
            owner(900_005, parent: me),                          // owner, parent alive -> kept
            worker(900_006, parent: nil),                        // parent unknown -> kept
            worker(900_007, parent: 1),                          // protected -> kept
            .init(processIdentifier: 900_008, arguments: ["/usr/bin/sleep", "60"], parentProcessIdentifier: 1, executableName: "sleep"),
        ]
        let plan = ClusterOrphanReaper.plan(processes: processes, liveEpochs: [liveEpoch], protectedProcessIdentifiers: [900_007])
        XCTAssertEqual(plan.candidates.map(\.processIdentifier), [900_001, 900_004])
        XCTAssertEqual(plan.candidates.map(\.role), [.worker, .owner])
        XCTAssertEqual(plan.candidates.first?.membershipEpoch, epoch)
        XCTAssertEqual(plan.kept.map(\.processIdentifier), [900_002, 900_003, 900_005, 900_006, 900_007])
        XCTAssertEqual(plan.kept.map(\.reason), ["parent \(me) is alive", "membership epoch is live", "parent \(me) is alive",
                                                "parent unknown", "this process or one it owns"])
    }

    func testRoleRecognizesOnlyWorkersAndOwners() {
        XCTAssertEqual(ClusterOrphanReaper.role(of: worker(1, parent: 1)), .worker)
        XCTAssertEqual(ClusterOrphanReaper.role(of: owner(1, parent: 1)), .owner)
        XCTAssertNil(ClusterOrphanReaper.role(of: .init(processIdentifier: 1, arguments: ["/opt/x/darkbloom", "start"], executableName: "darkbloom")))
        XCTAssertNil(ClusterOrphanReaper.role(of: .init(processIdentifier: 1, arguments: ["/opt/x/darkbloom", "cluster", "status"], executableName: "darkbloom")))
        // Without the executable name the first argument's basename decides.
        XCTAssertEqual(ClusterOrphanReaper.role(of: .init(processIdentifier: 1, arguments: ["/opt/x/darkbloom-cluster-worker"])), .worker)
        XCTAssertNil(ClusterOrphanReaper.membershipEpoch(of: worker(1, parent: 1, epoch: "not-a-uuid")))
    }

    func testSweepWaitsForTheContractThenTermsThenKillsOnlyWhatIgnoredTerm() {
        let plan = ClusterOrphanReaper.Plan(candidates: [
            .init(processIdentifier: 11, role: .worker, membershipEpoch: nil, startedAt: 1_000, reason: "parent is gone"),
            .init(processIdentifier: 12, role: .worker, membershipEpoch: nil, startedAt: 1_000, reason: "parent is gone"),
            .init(processIdentifier: 13, role: .owner, membershipEpoch: nil, startedAt: 1_000, reason: "parent is gone"),
            .init(processIdentifier: 14, role: .worker, membershipEpoch: nil, startedAt: nil, reason: "parent is gone"),
            // Its number is reused by another process (another start time) before the grace ends.
            .init(processIdentifier: 15, role: .worker, membershipEpoch: nil, startedAt: 1_000, reason: "parent is gone"),
        ], kept: [])
        final class Fake: @unchecked Sendable {
            let lock = NSLock()
            var clock: UInt64 = 0
            var signals: [(Int32, Int32)] = []
            // pid -> (dies after TERM, dies after KILL, dies by itself at clock)
            var endsByItselfAt: [Int32: UInt64] = [11: 3_000_000_000]
            var diesOnTerm: Set<Int32> = [12]
            var diesOnKill: Set<Int32> = [13]
            var dead: Set<Int32> = []
        }
        let fake = Fake()
        var actions = ClusterOrphanReaper.Actions()
        actions.now = { fake.lock.withLock { fake.clock } }
        actions.sleep = { n in fake.lock.withLock { fake.clock += n } }
        actions.wallClock = { 1_000 + 10 } // every candidate started 10 s ago (its age is not its grace)
        actions.isAlive = { pid in
            fake.lock.withLock {
                if fake.dead.contains(pid) { return false }
                if let at = fake.endsByItselfAt[pid], fake.clock >= at { fake.dead.insert(pid); return false }
                return true
            }
        }
        // Start times: the planned 1_000 while the process lives; pid 15's number holds a newer process from 2 s on.
        let alive = actions.isAlive
        actions.startTime = { pid in
            if pid == 15 { return fake.lock.withLock { fake.clock } >= 2_000_000_000 ? 2_000 : 1_000 }
            return alive(pid) ? 1_000 : nil
        }
        actions.signal = { pid, signal in
            fake.lock.withLock {
                fake.signals.append((pid, signal))
                if signal == SIGTERM, fake.diesOnTerm.contains(pid) { fake.dead.insert(pid) }
                if signal == SIGKILL, fake.diesOnKill.contains(pid) { fake.dead.insert(pid) }
            }
        }
        var limits = ClusterOrphanReaper.Limits()
        limits.contractGraceNanoseconds = 20_000_000_000 // from the sweep's start, for all candidates
        limits.killMarginNanoseconds = 2_000_000_000
        limits.reapMarginNanoseconds = 1_000_000_000
        limits.pollNanoseconds = 500_000_000
        let results = ClusterOrphanReaper.sweepProcesses(plan, limits: limits, actions: actions)
        XCTAssertEqual(results.map(\.outcome), [.endedByItself, .endedAfterTerm, .endedAfterKill, .unverified, .replaced])
        // 11 was never signalled; 12 got TERM only; 13 got TERM then KILL; 14 (identity unknown) and 15
        // (number reused by another process) were never signalled at all.
        XCTAssertEqual(fake.signals.map { "\($0.0):\($0.1)" }, ["12:\(SIGTERM)", "13:\(SIGTERM)", "13:\(SIGKILL)"])
        // 11 ended by itself 3 s into the grace and waited only that long.
        XCTAssertEqual(results[0].waitedNanoseconds, 3_000_000_000)
        XCTAssertEqual(results[3].waitedNanoseconds, 0)
        // A sweep with an unverified candidate is not clean.
        XCTAssertFalse(ClusterOrphanReaper.Report(at: 0, processes: results, kept: [], journal: "nothingToRecover",
            bootstrapDirectoriesRemoved: [], stagingEntriesRemoved: [], errors: []).clean)
    }

    /// A fake table on a fake clock for the grace cases: `endsAt` processes
    /// end by themselves at that clock, every other one on SIGTERM. Returns
    /// the results and each signal with the clock it was sent at.
    private func sweepOnFakeClock(_ candidates: [ClusterOrphanReaper.Candidate], startedAgoSeconds: Double,
                                  endsAt: [Int32: UInt64], grace: UInt64) -> ([ClusterOrphanReaper.ProcessResult], [String]) {
        final class Fake: @unchecked Sendable {
            let lock = NSLock(); var clock: UInt64 = 0; var dead: Set<Int32> = []; var sent: [String] = []
        }
        let fake = Fake()
        var actions = ClusterOrphanReaper.Actions()
        actions.now = { fake.lock.withLock { fake.clock } }
        actions.sleep = { n in fake.lock.withLock { fake.clock += n } }
        actions.wallClock = { 1_000 + startedAgoSeconds }
        actions.startTime = { pid in
            fake.lock.withLock {
                if fake.dead.contains(pid) { return nil }
                if let at = endsAt[pid], fake.clock >= at { fake.dead.insert(pid); return nil }
                return 1_000
            }
        }
        actions.signal = { pid, signal in
            fake.lock.withLock { fake.sent.append("\(pid):\(signal)@\(fake.clock / 1_000_000_000)s"); if signal == SIGTERM { fake.dead.insert(pid) } }
        }
        var limits = ClusterOrphanReaper.Limits()
        limits.contractGraceNanoseconds = grace; limits.killMarginNanoseconds = 2_000_000_000
        limits.reapMarginNanoseconds = 1_000_000_000; limits.pollNanoseconds = 500_000_000
        let results = ClusterOrphanReaper.sweepProcesses(.init(candidates: candidates, kept: []), limits: limits, actions: actions)
        return (results, fake.lock.withLock { fake.sent })
    }

    /// A worker that served for an hour and lost its owner just now is only
    /// starting its contract: the grace runs from its parent's death (at the
    /// latest the sweep's start), never from the process's start.
    func testGraceRunsFromTheParentsDeathNotFromTheProcessStart() {
        let candidate = ClusterOrphanReaper.Candidate(processIdentifier: 21, role: .worker, membershipEpoch: nil,
                                                      startedAt: 1_000, reason: "parent is gone")
        let (results, sent) = sweepOnFakeClock([candidate], startedAgoSeconds: 3_600, endsAt: [21: 15_000_000_000],
                                               grace: 20_000_000_000)
        XCTAssertEqual(results.map(\.outcome), [.endedByItself], "signalled at once: \(sent)")
        XCTAssertEqual(sent, [], "a worker inside its contract is never signalled")
        XCTAssertEqual(results.first?.waitedNanoseconds, 15_000_000_000)
    }

    /// Candidates are handled one after the other, but the grace is one
    /// deadline for all of them: the second is not given a second grace.
    func testOneGraceForAllCandidatesOfASweep() {
        let candidates = [21, 22].map { ClusterOrphanReaper.Candidate(processIdentifier: Int32($0), role: .worker,
                                                                       membershipEpoch: nil, startedAt: 1_000, reason: "parent is gone") }
        let (results, sent) = sweepOnFakeClock(candidates, startedAgoSeconds: 0, endsAt: [:], grace: 20_000_000_000)
        XCTAssertEqual(results.map(\.outcome), [.endedAfterTerm, .endedAfterTerm])
        XCTAssertEqual(sent, ["21:\(SIGTERM)@20s", "22:\(SIGTERM)@20s"])
    }

    /// The grace covers the forced exit's longest run: the dead-man and its
    /// one extension, after the lease and the owner's longest allowance.
    func testContractGraceCoversTheDeadManAndItsOneExtension() {
        XCTAssertEqual(ClusterForcedExitBounds.longestNanoseconds(), 2 * ClusterForcedExitBounds.deadManNanoseconds)
        XCTAssertEqual(ClusterOrphanReaper.contractGraceNanoseconds,
                       ClusterWorkerLease.ttlNanoseconds + ClusterWorkerSignalPolicy.maximumAllowanceNanoseconds + 40_000_000_000)
    }

    /// A real reparented process named as the worker: the sweep ends it with
    /// SIGTERM; one that ignores SIGTERM is ended by SIGKILL after the margin.
    /// (A copy of a system binary cannot run on this macOS, so the fake worker
    /// is a four-line C program compiled here.)
    func testRealOrphansAreEndedTermFirstThenKill() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reaper-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = root.appendingPathComponent("darkbloom-cluster-worker").path
        let source = root.appendingPathComponent("fake.c")
        try Data("""
        #include <signal.h>
        #include <string.h>
        #include <unistd.h>
        int main(int argc, char **argv) { for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "--ignore-term")) signal(SIGTERM, SIG_IGN); for (;;) sleep(1); }
        """.utf8).write(to: source)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc"); compiler.arguments = [source.path, "-o", fake]
        compiler.standardOutput = FileHandle.nullDevice; compiler.standardError = FileHandle.nullDevice
        try compiler.run(); compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0, "the fake worker compiled")
        let polite = UUID().uuidString.lowercased(), stubborn = UUID().uuidString.lowercased()
        // The intermediate shell exits at once; its children are reparented.
        let script = "'\(fake)' --membership-epoch \(polite) & "
            + "'\(fake)' --ignore-term --membership-epoch \(stubborn) & exit 0"
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh"); launcher.arguments = ["-c", script]
        launcher.standardOutput = FileHandle.nullDevice; launcher.standardError = FileHandle.nullDevice
        try launcher.run(); launcher.waitUntilExit()
        func find() -> [ClusterProcessTable.Entry] {
            ClusterProcessTable.running().filter { ClusterOrphanReaper.membershipEpoch(of: $0).map { [polite, stubborn].contains($0) } ?? false }
        }
        var found: [ClusterProcessTable.Entry] = []
        for _ in 0..<50 { found = find(); if found.count == 2, found.allSatisfy({ $0.parentProcessIdentifier == 1 }) { break }; usleep(100_000) }
        defer { for entry in found { kill(entry.processIdentifier, SIGKILL) } }
        XCTAssertEqual(found.count, 2, "both fake workers running and reparented: \(found)")
        let plan = ClusterOrphanReaper.plan(processes: found, liveEpochs: [], protectedProcessIdentifiers: ClusterOrphanReaper.ownLineage())
        XCTAssertEqual(plan.candidates.count, 2, "\(plan)")
        XCTAssertEqual(plan.candidates.map(\.reason), ["parent is gone", "parent is gone"])
        // A live epoch is never reaped, whatever its parent.
        XCTAssertEqual(ClusterOrphanReaper.plan(processes: found, liveEpochs: [polite, stubborn], protectedProcessIdentifiers: []).candidates, [])
        var limits = ClusterOrphanReaper.Limits()
        limits.contractGraceNanoseconds = 0; limits.killMarginNanoseconds = 1_500_000_000; limits.reapMarginNanoseconds = 2_000_000_000
        let results = ClusterOrphanReaper.sweepProcesses(plan, limits: limits)
        let byEpoch = Dictionary(uniqueKeysWithValues: results.map { ($0.candidate.membershipEpoch!, $0.outcome) })
        XCTAssertEqual(byEpoch[polite], .endedAfterTerm)
        XCTAssertEqual(byEpoch[stubborn], .endedAfterKill)
        XCTAssertEqual(find().count, 0, "nothing left")
        let report = ClusterTeardownVerification.report(at: 0, processes: ClusterProcessTable.running(), liveEpochs: [],
            protectedProcessIdentifiers: ClusterOrphanReaper.ownLineage(), wired: nil, journal: "absentOrEmpty", staleBootstrapDirectories: [])
        XCTAssertFalse(report.processes.contains { [polite, stubborn].contains($0.membershipEpoch ?? "") })
    }

    func testStaleBootstrapDirectoriesAreThoseWhoseSocketDoesNotAnswer() throws {
        // A short root: a UNIX socket path is at most 103 bytes.
        let root = URL(fileURLWithPath: "/private/tmp/orphan-check-" + String(UUID().uuidString.lowercased().prefix(8)), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        // A dead listener left its directory and socket file; a directory with no socket at all; a live listener.
        let dead = root.appendingPathComponent("darkbloom-bootstrap-dead0001").path
        let empty = root.appendingPathComponent("darkbloom-bootstrap-empty001").path
        let live = root.appendingPathComponent("darkbloom-bootstrap-live0001").path
        let other = root.appendingPathComponent("unrelated-dir").path
        for directory in [dead, empty, live, other] { XCTAssertEqual(mkdir(directory, 0o700), 0) }
        func bind(_ path: String) -> Int32 {
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutablePointer(to: &address.sun_path) { p in p.withMemoryRebound(to: CChar.self, capacity: 104) { base in _ = path.withCString { strncpy(base, $0, 103) } } }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            XCTAssertEqual(bound, 0, "bind \(path): \(errno)")
            return fd
        }
        let deadFD = bind(dead + "/channel"); close(deadFD) // the file stays, nobody listens
        let liveFD = bind(live + "/channel"); XCTAssertEqual(listen(liveFD, 1), 0)
        defer { close(liveFD) }
        let later = Date().timeIntervalSince1970 + 10
        XCTAssertEqual(ClusterOrphanReaper.staleBootstrapDirectories(under: root.path, now: later), [dead, empty])
        // A directory just made is never stale (its listener may not have bound yet).
        XCTAssertEqual(ClusterOrphanReaper.staleBootstrapDirectories(under: root.path), [])
        // Nothing connected to the live listener: its pending accept queue is empty (a connect from the
        // check would have been accepted in place of the child the listener waits for).
        var pending = pollfd(fd: liveFD, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&pending, 1, 0), 0, "the stale check connected to a live listener")
        XCTAssertFalse(ClusterOrphanReaper.removeBootstrapDirectory(dead), "only the product prefix is ever removed")
    }

    func testStaleStagingEntriesAreOldEpochDirectoriesThatAreNotLive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("staging-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let old = UUID().uuidString.lowercased(), fresh = UUID().uuidString.lowercased(), live = UUID().uuidString.lowercased()
        // (An upper-case spelling is not a canonical epoch either, but the file
        // system here folds case, so it is not created beside the lower-case one.)
        for name in [old, fresh, live, "not-an-epoch", "x" + UUID().uuidString.lowercased()] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        let now = Date().timeIntervalSince1970
        let stale = ClusterOrphanReaper.staleStagingEntries(roots: [root], liveEpochs: [live], graceSeconds: 60, now: now + 120)
        XCTAssertEqual(Set(stale.map(\.lastPathComponent)), [old, fresh], "both old enough at now+120; the live one and non-epochs never")
        XCTAssertEqual(ClusterOrphanReaper.staleStagingEntries(roots: [root], liveEpochs: [live], graceSeconds: 60, now: now), [])
    }

    /// Review round 4: `darkbloom cluster cancel-all` compared each owner's
    /// first argument with its own. An owner is launched by absolute path
    /// (`ClusterLocalOwnerConfiguration`), while a person types `darkbloom`
    /// (the shell passes the word as typed), so the command signalled nothing
    /// on the user path. The decision now compares the images the kernel
    /// reports for both processes; spelling of the first argument is ignored.
    func testCancelAllTargetsOwnersRunningThisImageWhateverTheirFirstArgument() {
        let installed = "/opt/x/darkbloom"
        let processes = [
            owner(900_201, parent: getpid()),                                                   // same image, absolute argv[0]
            .init(processIdentifier: 900_202, arguments: ["darkbloom", "cluster", "worker-owner", "--stdio"],
                  parentProcessIdentifier: 1, executableName: "darkbloom", startedAt: 1_000), // same image, bare argv[0]
            .init(processIdentifier: 900_203, arguments: ["/old/darkbloom", "cluster", "worker-owner", "--stdio"],
                  parentProcessIdentifier: 1, executableName: "darkbloom", startedAt: 1_000), // another install
            owner(900_204, parent: 1),                                                          // image unreadable
            worker(900_205, parent: 1),                                                         // workers are never signalled
            owner(900_206, parent: 1),                                                          // this process's own lineage
        ]
        let images: [Int32: String] = [900_201: installed, 900_202: installed, 900_203: "/old/darkbloom", 900_206: installed]
        let targets = ClusterOrphanReaper.cancelTargets(processes: processes, ownImage: installed,
                                                        protectedProcessIdentifiers: [900_206], image: { images[$0] })
        XCTAssertEqual(targets.owners, [900_201, 900_202, 900_203, 900_204])
        XCTAssertEqual(targets.workers, [900_205])
        XCTAssertEqual(targets.signal, [900_201, 900_202], "only owners whose running image is this one")
        // Without its own image the command signals nothing.
        XCTAssertEqual(ClusterOrphanReaper.cancelTargets(processes: processes, ownImage: nil, protectedProcessIdentifiers: [],
                                                         image: { images[$0] }).signal, [])
    }

    /// Review round 4: every caller of the sweep (`darkbloom cluster reap`,
    /// a member's start and end, the supervisor before a restart) names no
    /// live epoch, and a live session's staging directory keeps the mtime of
    /// its first record (its writes land one level down, in `rank<r>`). So a
    /// session serving longer than the grace lost its staging directory, and
    /// the record being written, to any sweep on its Mac. A running worker
    /// started with an epoch (whatever its parent) makes that epoch live.
    func testStagingOfAnEpochARunningWorkerHoldsIsNeverStale() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("staging-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let serving = UUID().uuidString.lowercased(), dead = UUID().uuidString.lowercased(), orphaned = UUID().uuidString.lowercased()
        for name in [serving, dead, orphaned] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name).appendingPathComponent("rank0"),
                                                    withIntermediateDirectories: true)
        }
        let me = getpid()
        // The serving session's worker has a live parent; the orphaned one's
        // parent is gone (the reaper's to end, but while it runs its writes
        // are still its own).
        let running = [worker(900_101, parent: me, epoch: serving), worker(900_102, parent: 1, epoch: orphaned),
                       owner(900_103, parent: me)]
        XCTAssertEqual(ClusterOrphanReaper.runningWorkerEpochs(running), [serving, orphaned])
        let later = Date().timeIntervalSince1970 + 3_600
        let stale = ClusterOrphanReaper.staleStagingEntries(roots: [root], liveEpochs: [], graceSeconds: 60, now: later,
                                                            runningWorkers: running)
        XCTAssertEqual(stale.map(\.lastPathComponent), [dead], "only the epoch no running worker holds")
    }

    func testEnvironmentGuardsYieldToACanonicalPinnedValueOnly() {
        let base = ["PATH": "/usr/bin:/bin"]
        let applied = ClusterWorkerEnvironmentGuards.apply(to: base, ownerEnvironment: [:])
        XCTAssertEqual(applied["MLX_MAX_OPS_PER_BUFFER"], "16")
        // No megabyte value: MLX's own per-chip cap (40-50 MB a command
        // buffer) applies; a default of its own could only loosen it.
        XCTAssertNil(applied["MLX_MAX_MB_PER_BUFFER"], "a guard never loosens MLX's own per-chip cap")
        XCTAssertEqual(applied["PATH"], "/usr/bin:/bin")
        let pinned = ClusterWorkerEnvironmentGuards.apply(to: base, ownerEnvironment: ["MLX_MAX_OPS_PER_BUFFER": "4", "MLX_MAX_MB_PER_BUFFER": "lots"])
        XCTAssertEqual(pinned["MLX_MAX_OPS_PER_BUFFER"], "4", "the operator's value is kept")
        XCTAssertNil(pinned["MLX_MAX_MB_PER_BUFFER"], "free text never reaches a worker")
        let operatorCap = ClusterWorkerEnvironmentGuards.apply(to: base, ownerEnvironment: ["MLX_MAX_MB_PER_BUFFER": "24"])
        XCTAssertEqual(operatorCap["MLX_MAX_MB_PER_BUFFER"], "24", "an operator's own canonical cap still reaches the worker")
        let fixed = ClusterWorkerEnvironmentGuards.apply(to: ["MLX_MAX_OPS_PER_BUFFER": "8"], ownerEnvironment: ["MLX_MAX_OPS_PER_BUFFER": "4"])
        XCTAssertEqual(fixed["MLX_MAX_OPS_PER_BUFFER"], "8", "a value the plan already fixed is not replaced")
        XCTAssertFalse(ClusterWorkerEnvironmentGuards.isCanonical("0"))
        XCTAssertFalse(ClusterWorkerEnvironmentGuards.isCanonical("-1"))
        XCTAssertFalse(ClusterWorkerEnvironmentGuards.isCanonical("1234567890123"))
    }
}

final class ClusterTeardownVerificationTests: XCTestCase {
    private let gib: UInt64 = 1 << 30

    func testWiredToleranceAndBaselineAreDerivedFromTheMac() {
        XCTAssertEqual(ClusterTeardownVerification.toleranceBytes(physicalBytes: 64 * gib), gib)
        XCTAssertEqual(ClusterTeardownVerification.toleranceBytes(physicalBytes: 256 * gib), 2 * gib)
        let given = ClusterTeardownVerification.wiredFinding(samples: [12 * gib, 9 * gib, 10 * gib], baselineBytes: 8 * gib, physicalBytes: 256 * gib)!
        XCTAssertEqual(given.excessBytes, gib); XCTAssertTrue(given.withinTolerance); XCTAssertEqual(given.baseline, "given")
        let over = ClusterTeardownVerification.wiredFinding(samples: [40 * gib, 30 * gib], baselineBytes: 8 * gib, physicalBytes: 256 * gib)!
        XCTAssertEqual(over.excessBytes, 22 * gib); XCTAssertFalse(over.withinTolerance)
        let idle = ClusterTeardownVerification.wiredFinding(samples: [9 * gib], baselineBytes: nil, physicalBytes: 128 * gib)!
        XCTAssertEqual(idle.baselineBytes, 16 * gib); XCTAssertEqual(idle.excessBytes, 0); XCTAssertEqual(idle.baseline, "idle")
        XCTAssertNil(ClusterTeardownVerification.wiredFinding(samples: [], baselineBytes: nil, physicalBytes: 128 * gib))
    }

    func testReportNamesEveryLeftoverAndPassesOnlyWhenThereIsNone() {
        let epoch = UUID().uuidString.lowercased()
        let worker = ClusterProcessTable.Entry(processIdentifier: 900_010, arguments: ["/x/darkbloom-cluster-worker", "--membership-epoch", epoch],
                                               parentProcessIdentifier: 1, executableName: "darkbloom-cluster-worker")
        let clean = ClusterTeardownVerification.report(at: 1, processes: [], liveEpochs: [], protectedProcessIdentifiers: [],
            wired: .init(samples: [1], baselineBytes: 2, toleranceBytes: 3, excessBytes: 0, withinTolerance: true, baseline: "given"),
            journal: "absentOrEmpty", staleBootstrapDirectories: [])
        XCTAssertTrue(clean.passed); XCTAssertEqual(clean.reasons, [])
        let dirty = ClusterTeardownVerification.report(at: 1, processes: [worker], liveEpochs: [], protectedProcessIdentifiers: [],
            wired: .init(samples: [5 << 30], baselineBytes: 1 << 30, toleranceBytes: 1 << 30, excessBytes: 4 << 30, withinTolerance: false, baseline: "given"),
            journal: "stranded", staleBootstrapDirectories: ["/private/tmp/darkbloom-bootstrap-abc"])
        XCTAssertFalse(dirty.passed)
        XCTAssertEqual(dirty.reasons, ["1 cluster process(es) still running", "wired memory 4096 MiB above its baseline (tolerance 1024 MiB)",
                                       "device journal names a session whose owner is gone", "1 stale bootstrap director(ies)"])
        XCTAssertEqual(dirty.processes.first?.membershipEpoch, epoch)
        // A worker of a session this process holds is not a leftover.
        let serving = ClusterTeardownVerification.report(at: 1, processes: [worker], liveEpochs: [epoch], protectedProcessIdentifiers: [],
            wired: nil, journal: "heldByLiveOwner", staleBootstrapDirectories: [])
        XCTAssertTrue(serving.passed, "\(serving.reasons)")
        let data = try! JSONEncoder().encode(dirty)
        let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(object["schema"] as? String, "darkbloom_cluster_teardown_verification_v1")
        XCTAssertEqual(object["passed"] as? Bool, false)
    }

    func testJournalInspectionReadsWithoutChanging() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("journal-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let device = root.appendingPathComponent("device", isDirectory: true)
        XCTAssertEqual(try ClusterDeviceLeaseRecovery.inspect(directoryURL: device), .absentOrEmpty, "no directory")
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        XCTAssertEqual(try ClusterDeviceLeaseRecovery.inspect(directoryURL: device), .absentOrEmpty, "no file")
        let file = device.appendingPathComponent("native-device.lease")
        let ids = (0..<4).map { _ in UUID().uuidString.lowercased() }
        let record = "{\"schema\":\"darkbloom_native_lease_v1\",\"clusterID\":\"c\",\"peerID\":\"p\",\"rank\":1,"
            + "\"membershipEpoch\":\"\(ids[0])\",\"leaseID\":\"\(ids[1])\",\"ownerIncarnation\":\"\(ids[2])\",\"nativeLaunchID\":\"\(ids[3])\"}"
        try Data(record.utf8).write(to: file); XCTAssertEqual(chmod(file.path, 0o600), 0)
        guard case .stranded(let parsed) = try ClusterDeviceLeaseRecovery.inspect(directoryURL: device) else { return XCTFail("stranded expected") }
        XCTAssertEqual(parsed.membershipEpoch, ids[0]); XCTAssertEqual(parsed.rank, 1)
        XCTAssertEqual(try Data(contentsOf: file), Data(record.utf8), "inspection changed nothing")
        // A live owner holds the exclusive lock.
        let holder = open(file.path, O_RDWR); XCTAssertEqual(flock(holder, LOCK_EX | LOCK_NB), 0)
        XCTAssertEqual(try ClusterDeviceLeaseRecovery.inspect(directoryURL: device), .heldByLiveOwner)
        close(holder)
        try Data("garbage".utf8).write(to: file)
        XCTAssertEqual(try ClusterDeviceLeaseRecovery.inspect(directoryURL: device), .unreadable)
        try Data().write(to: file)
        XCTAssertEqual(try ClusterDeviceLeaseRecovery.inspect(directoryURL: device), .absentOrEmpty)
    }
}
