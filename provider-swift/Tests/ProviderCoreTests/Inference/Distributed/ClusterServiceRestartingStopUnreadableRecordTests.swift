import Foundation
import Testing
@testable import ProviderCore

/// The setup record a restarting stop cannot read, or cannot write. A step puts the pair's start back when it ends, so
/// what it does not know must never become a start: a pair a person stopped stays stopped whatever fails. The other
/// way round is the accepted limit: a write that fails can leave a pair stopped that nobody stopped.
///
/// A read of the record outside its lock fails while another writer replaces the record ("Configuration input changed
/// while reading"). Here it fails on a mode the owner-only read refuses, which an update under the record's lock
/// still reads (and writes back owner-only). A record no read decodes stands for one that cannot be read at all.
extension ClusterServiceRestartingStopTests {
    private static func refuseReadsOutsideTheLock(_ store: ClusterSetupStore) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.paths.record.path)
        try #require((try? store.readRecord()) == nil, "the read outside the record's lock did not fail")
    }

    /// The record as it is on disk, in whatever mode the test left it.
    private static func recordOnDisk(_ store: ClusterSetupStore) throws -> ClusterSetupRecord {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.paths.record.path)
        return try store.readRecord()
    }

    /// A step the previous run never ended: its mark, the pair's start cleared by its stop.
    private static func leaveAMark(_ store: ClusterSetupStore, startedAt: Double = 1_000_000) throws {
        _ = try store.updateRecord {
            $0.leadership?.serving = false
            $0.restartingStop = .init(step: ClusterRestartingStop.Step.memoryReplan.rawValue, stopsAsked: $0.stopsAsked ?? 0,
                                      startedAt: startedAt)
        }
    }

    /// A person stopped the pair. A step then runs on it while the record cannot be read outside its lock. The step
    /// reads where it starts from under the lock: the pair is not started, so it runs as it is, marks nothing and puts
    /// no start back.
    @Test(arguments: ClusterRestartingStop.Step.allCases)
    func aStepOnAStoppedPairWhoseRecordCannotBeReadOutsideItsLockStartsNothing(_ step: ClusterRestartingStop.Step) throws {
        let (macs, service) = try leader()
        try withExtendedLifetime(macs) {
            guard case .success = service.controlLive.localStop(seconds: 1, asked: true, stopPeer: {}) else {
                Issue.record("the person's stop failed"); return
            }
            try Self.refuseReadsOutsideTheLock(service.store)
            let ran = ClusterApprovalRecorder<Bool>()
            let ended: Void? = service.restartingStops.run(step) { ran.append(true) }
            #expect(ended != nil && ran.values == [true], "\(step.rawValue): a step on a pair that is not started runs as it is")
            let record = try Self.recordOnDisk(service.store)
            #expect(record.leadership?.serving == false, "\(step.rawValue) started a pair a person stopped")
            #expect(record.stopsAsked == 1 && record.restartingStopMarks.isEmpty, "\(step.rawValue): \(record.restartingStopMarks)")
        }
    }

    /// The same through the approval check's own change, as it decides it for a pair that does not serve: the pair
    /// was started by it, although a person had stopped it and nothing was stopped for the change.
    @Test func anApprovalChangeOfAStoppedPairWhoseRecordCannotBeReadOutsideItsLockStartsNothing() throws {
        let (macs, service) = try leader()
        try withExtendedLifetime(macs) {
            guard case .success = service.controlLive.localStop(seconds: 1, asked: true, stopPeer: {}) else {
                Issue.record("the person's stop failed"); return
            }
            try Self.refuseReadsOutsideTheLock(service.store)
            let result = service.changeApproval(.converge(nil), serving: false, .init(
                stop: { Issue.record("stopped a pair that does not serve"); return .success([]) },
                drained: { Issue.record("waited for a drain"); return true },
                serve: { Issue.record("started a pair that does not serve"); return .success([]) },
                sendToPeer: { _ in }), say: { _ in })
            #expect(result?.changed == true, "the change did not run: \(String(describing: result))")
            let record = try Self.recordOnDisk(service.store)
            #expect(record.leadership?.serving == false, "the approval change started a pair a person stopped")
            #expect(record.stopsAsked == 1 && record.restartingStopMarks.isEmpty)
        }
    }

    /// The record cannot be read under its lock either. Whether the pair is started is not known, so there is no
    /// telling whether a start is owed: no step begins, nothing stops, and nothing is written.
    @Test(arguments: ClusterRestartingStop.Step.allCases)
    func noStepBeginsOnARecordItCannotRead(_ step: ClusterRestartingStop.Step) throws {
        let (macs, coordinator) = try Self.offeredPair()
        defer { coordinator.close() }
        try withExtendedLifetime(macs) {
            let started = try macs.startedLeaderService(powerAssertionReason: "Cluster restarting stop test " + UUID().uuidString)
            let store = started.store, service = Self.restarted(macs)
            let unreadable = Data("not a setup record".utf8)
            try unreadable.write(to: store.paths.record)
            // The step through its own entry point, then the restarting stop alone.
            let crash = Crash(at: .marked, store: store)
            Self.drive(step, service, crash)
            #expect(crash.passed.isEmpty, "\(step.rawValue) began on a record it could not read: \(crash.passed)")
            let ran = ClusterApprovalRecorder<Bool>()
            let ended: Void? = service.restartingStops.run(step) { ran.append(true) }
            #expect(ended == nil && ran.values.isEmpty, "\(step.rawValue) ran on a record it could not read")
            #expect(try Data(contentsOf: store.paths.record) == unreadable, "\(step.rawValue) wrote over the record it could not read")
        }
    }

    /// The next run's write that puts the start back fails. Its log says the start is back only when it is: the pair
    /// stays stopped with its mark, and the run after that puts the start back and says so.
    @Test func theNextRunSaysTheStartIsBackOnlyOnceItIsWritten() throws {
        let (macs, service) = try leader()
        try withExtendedLifetime(macs) {
            try Self.leaveAMark(service.store)
            // The record's directory takes no new file: the update's staged write fails after its change was decided.
            let directory = service.store.paths.directory.path
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory)
            let failed = Self.restarted(macs).resumeInterruptedRestart(now: 1_000_005)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
            var record = try service.store.readRecord()
            #expect(failed == nil, "the log said the start is back though its write failed: \(failed ?? "")")
            #expect(record.leadership?.serving == false && record.restartingStopMarks.count == 1)
            let written = Self.restarted(macs).resumeInterruptedRestart(now: 1_000_010)
            record = try service.store.readRecord()
            #expect(written == "the previous run of this Mac's cluster service was ended while it planned the model again for the "
                + "Macs' memory (10 s ago), after it stopped the pair: the pair's start is put back")
            #expect(record.leadership?.serving == true && record.restartingStopMarks.isEmpty)
        }
    }

    /// A person stops this Mac's pair while it is down, which counts no stop, so the stop drops the mark of a step that
    /// a restart ended (`darkbloom stop`). The record cannot be read outside its lock just then. The next run must
    /// not put the start back.
    @Test func aStopWhileThePairIsDownStandsThoughTheRecordCannotBeReadOutsideItsLock() throws {
        let (macs, service) = try leader()
        try withExtendedLifetime(macs) {
            try Self.leaveAMark(service.store)
            try Self.refuseReadsOutsideTheLock(service.store)
            #expect(ClusterRestartingStop(store: service.store).forget(), "the stop did not drop the mark")
            _ = try Self.recordOnDisk(service.store)
            let line = Self.restarted(macs).resumeInterruptedRestart(now: 1_000_005)
            let record = try service.store.readRecord()
            #expect(line == nil && record.leadership?.serving == false, "the next run started a pair stopped while it was down: \(line ?? "")")
            #expect(record.restartingStopMarks.isEmpty)
        }
    }

    /// A stop that cannot drop the mark says so, so that it is not taken for done (`darkbloom stop` then fails, and a
    /// release for single-Mac serving ends as not stopped): the mark it left would start the pair at the next run.
    @Test func aStopWhileThePairIsDownThatCannotBeRecordedSaysSo() throws {
        let (macs, service) = try leader()
        try withExtendedLifetime(macs) {
            try Self.leaveAMark(service.store)
            // The command lock's file is there, as after any cluster command; the directory then takes no new file.
            try #require(ClusterControlCommandLock.acquire(seconds: 0, file: Self.commandLock(service))).release()
            let directory = service.store.paths.directory.path
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory)
            let forgotten = ClusterRestartingStop(store: service.store).forget()
            let released = ClusterService.releaseForSingleMac(seconds: 1, paths: macs.leader.paths, commandSeconds: 1)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
            #expect(!forgotten && released == .partNotStopped, "\(forgotten), \(released)")
            #expect(try service.store.readRecord().restartingStopMarks.count == 1)
            // Nothing to drop is nothing to write: a Mac with no record gets none.
            let unpaired = ClusterSetupStore(paths: .init(paths: macs.follower.paths))
            try #require(!FileManager.default.fileExists(atPath: unpaired.paths.record.path))
            #expect(ClusterRestartingStop(store: unpaired).forget())
            #expect(!FileManager.default.fileExists(atPath: unpaired.paths.record.path), "a stop wrote a record where there was none")
        }
    }

    /// Going back to single-Mac serving clears this Mac's saved start (`darkbloom start --solo`, `darkbloom stop` with
    /// a leftover part). The record cannot be read outside its lock just then: the start must be cleared all the
    /// same, or the cluster service starts the part again.
    @Test func aStopForSingleMacServingClearsTheStartThoughTheRecordCannotBeReadOutsideItsLock() throws {
        let (macs, service) = try leader()
        try withExtendedLifetime(macs) {
            try Self.refuseReadsOutsideTheLock(service.store)
            let released = ClusterService.releaseForSingleMac(seconds: 1, paths: macs.leader.paths, commandSeconds: 1)
            let record = try Self.recordOnDisk(service.store)
            #expect(released == .released && record.leadership?.serving == false,
                    "\(released): the start is \(String(describing: record.leadership?.serving))")
        }
    }

    /// The accepted limit, the other way round: a step whose last write fails leaves the pair stopped although nobody
    /// stopped it. Its mark stays, so the service's next run puts the start back.
    @Test func aStepWhoseLastWriteFailsLeavesItsMarkForTheNextRun() throws {
        let (macs, service) = try leader()
        try withExtendedLifetime(macs) {
            let directory = service.store.paths.directory.path
            let ended = service.restartingStops.run(.memoryReplan) { () -> Result<[String], ClusterOnboardingFailure> in
                let stopped = Self.stop(service) { throw ClusterSetupFailure("the other Mac did not answer within 30 s") }()
                try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory)
                return stopped
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
            guard case .failure = ended else { Issue.record("the step's stop did not fail: \(String(describing: ended))"); return }
            var record = try service.store.readRecord()
            #expect(record.leadership?.serving == false && record.restartingStopMarks.map(\.step) == [.some(.memoryReplan)],
                    "\(record.restartingStopMarks)")
            let line = Self.restarted(macs).resumeInterruptedRestart()
            record = try service.store.readRecord()
            #expect(line != nil && record.leadership?.serving == true && record.restartingStopMarks.isEmpty, "\(line ?? "no line")")
        }
    }
}
