/// The operator rollback API behind `darkbloom update --rollback`: its plan,
/// each refusal, and a failure finished under the same lease.

import Darwin
import Foundation
import Testing
@testable import ProviderCore

@Suite("Operator rollback plan", .serialized)
struct UpdateRollbackPlanTests {
    @Test("the plan names the installed release, the predecessor and the generation it records")
    func planForPromotedAndPendingReleases() async throws {
        for promote in [true, false] {
            let installed = try await InstalledUpdate.make(promote: promote)
            let state = try installed.store.loadState()
            let plan = try installed.updater.rollbackPlan()
            #expect(plan == SelfUpdater.RollbackPlan(
                from: "2.0.0", fromIsCandidate: !promote, to: "1.0.0",
                toGeneration: try #require(state.predecessor).release.installGeneration,
                generation: state.installGeneration + 1))
            await installed.shutdown()
        }
    }

    @Test("the rollback's cluster hold keeps a cluster service out of its lock, taken as `ClusterService.run` takes it")
    func clusterHoldKeepsTheServiceOut() throws {
        // The resolved path: the directory check refuses a link in any component (`/var` is one).
        let temporary = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(temporary) }
        let directory = URL(fileURLWithPath: String(cString: temporary), isDirectory: true)
            .appendingPathComponent("cluster-hold-\(UUID().uuidString)/cluster-setup", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let lockFile = directory.appendingPathComponent("service.lock")

        let hold = try #require(try ClusterService.holdStopped(operation: "operator-rollback", lockFile: lockFile))
        let service = open(lockFile.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        #expect(service >= 0)
        defer { close(service) }
        #expect(flock(service, LOCK_EX | LOCK_NB) != 0, "no cluster service starts while the rollback holds it")
        hold.release()
        #expect(flock(service, LOCK_EX | LOCK_NB) == 0)
        #expect(try ClusterService.holdStopped(operation: "operator-rollback", lockFile: lockFile) == nil,
                "a running cluster service keeps the rollback out")
        _ = flock(service, LOCK_UN)
    }

    @Test("a plan confirmed before the lease must still hold under it")
    func confirmedPlanMustStillHold() async throws {
        let installed = try await InstalledUpdate.make(promote: true)
        defer { Task { await installed.shutdown() } }
        let plan = try installed.updater.rollbackPlan()
        let session = try installed.updater.beginUpdateSession(operation: "operator-rollback")
        defer { session.release() }
        try installed.updater.confirmRollbackPlan(plan, session: session)
        var state = try installed.store.loadState()
        state.installGeneration += 1
        try installed.store.writeState(state)
        #expect(throws: SelfUpdater.RollbackRefusal.self) { try installed.updater.confirmRollbackPlan(plan, session: session) }
        #expect(try installed.store.loadState().quarantine == nil)
    }

    @Test("rolling back a pending candidate quarantines it with its failed starts")
    func pendingCandidateRollsBack() async throws {
        let installed = try await InstalledUpdate.make(promote: false)
        defer { Task { await installed.shutdown() } }
        // The watchdog launches v2 once, and that start fails.
        let watchdog = watchdogRecovery(installed.updater)
        _ = await watchdog.recoverDownProvider(autoUpdateEnabled: false, now: 200)
        _ = await watchdog.recoverDownProvider(autoUpdateEnabled: false, now: 300)

        let plan = try installed.updater.rollbackPlan()
        let session = try installed.updater.beginUpdateSession(operation: "test-rollback")
        defer { session.release() }
        #expect(try installed.updater.rollBackToPredecessor(session: session, plan: plan) == "1.0.0")

        #expect(try installed.liveRelease() == "1.0.0")
        let state = try installed.store.loadState()
        #expect(state.candidate == nil)
        #expect(state.current?.version == "1.0.0")
        #expect(state.installGeneration == plan.generation)
        #expect(state.quarantine?.version == "2.0.0")
        #expect(state.quarantine?.failureCount == 1)
        #expect(state.quarantine?.reason.contains("update --rollback") == true)
    }

    @Test("each refusal leaves the install as it was")
    func refusals() async throws {
        // Never updated: nothing was retained.
        let fresh = try UpdateRecoveryFixture()
        defer { fresh.cleanup() }
        #expect(throws: SelfUpdater.RollbackRefusal.noPredecessor) {
            try fresh.updater(baseURL: URL(string: "http://127.0.0.1:9")!).rollbackPlan()
        }

        let installed = try await InstalledUpdate.make(promote: true)
        defer { Task { await installed.shutdown() } }

        // Another update holds the cross-process lease.
        let holder = try installed.updater.beginUpdateSession(operation: "watchdog-recovery")
        #expect {
            try installed.updater.rollbackPlan()
        } throws: { error in
            guard case .busy(let reason) = error as? SelfUpdater.RollbackRefusal else { return false }
            return reason.contains("watchdog-recovery")
        }
        holder.release()

        // A live bundle replaced outside the updater is not the recorded release.
        let liveBinary = installed.fixture.installRoot.appendingPathComponent("Darkbloom.app/Contents/MacOS/darkbloom")
        let original = try Data(contentsOf: liveBinary)
        try Data("hand-copied".utf8).write(to: liveBinary)
        #expect(throws: SelfUpdater.RollbackRefusal.installNotRecorded("2.0.0")) {
            try installed.updater.rollbackPlan()
        }
        try original.write(to: liveBinary)

        // A changed predecessor is never restored.
        let predecessorBinary = installed.fixture.installRoot
            .appendingPathComponent("recovery/predecessor/Darkbloom.app/Contents/MacOS/darkbloom")
        let retained = try Data(contentsOf: predecessorBinary)
        try Data("tampered".utf8).write(to: predecessorBinary)
        #expect {
            try installed.updater.rollbackPlan()
        } throws: { error in
            guard case .predecessorUnusable(let reason) = error as? SelfUpdater.RollbackRefusal else { return false }
            return reason.contains("hash mismatch")
        }
        try retained.write(to: predecessorBinary)
        #expect(try installed.liveRelease() == "2.0.0")
        #expect(try installed.store.loadState().quarantine == nil)

        // Once rolled back, the predecessor is installed: nothing older remains.
        let plan = try installed.updater.rollbackPlan()
        let session = try installed.updater.beginUpdateSession(operation: "test-rollback")
        try installed.updater.rollBackToPredecessor(session: session, plan: plan)
        #expect(throws: SelfUpdater.RollbackRefusal.nothingToRollBack(installed: "1.0.0")) {
            try installed.updater.rollbackPlan(session: session)
        }
        // A plan confirmed before the install changed is not carried out.
        #expect(throws: SelfUpdater.RollbackRefusal.self) {
            try installed.updater.rollBackToPredecessor(session: session, plan: plan)
        }
        session.release()
        #expect(try installed.liveRelease() == "1.0.0")
    }

    @Test("a promotion after confirmation is the same rollback; a newer install is not")
    func confirmationAgainstLaterChanges() async throws {
        let promotedLater = try await InstalledUpdate.make(promote: false)
        defer { Task { await promotedLater.shutdown() } }
        let pendingPlan = try promotedLater.updater.rollbackPlan()
        #expect(pendingPlan.fromIsCandidate)
        let health = watchdogRecovery(promotedLater.updater, stabilizationSeconds: 0).observeHealthyProvider(
            providerRunning: true,
            daemonState: DaemonState(pid: 4242, version: "2.0.0", writtenAt: 150, startedAt: 120),
            now: 150)
        #expect(health == .promoted(version: "2.0.0"))
        let promotedSession = try promotedLater.updater.beginUpdateSession(operation: "test-rollback")
        #expect(try promotedLater.updater.rollBackToPredecessor(session: promotedSession, plan: pendingPlan) == "1.0.0")
        promotedSession.release()

        let updatedLater = try await InstalledUpdate.make(promote: true)
        defer { Task { await updatedLater.shutdown() } }
        let plan = try updatedLater.updater.rollbackPlan()
        let newer = try UpdateRecoveryFixture(oldVersion: "1.0.0", newVersion: "3.0.0")
        defer { newer.cleanup() }
        let newerMock = MockCoordinator(release: newer.mockReleaseFixture(), releaseArtifact: newer.artifact)
        let newerURL = try await newerMock.start()
        defer { Task { await newerMock.shutdown() } }
        let v2Updater = SelfUpdater(
            coordinatorBaseURL: newerURL.absoluteString, installRoot: updatedLater.fixture.installRoot,
            verifyCodeSignatures: false, currentVersion: "2.0.0")
        guard case .updated(_, "3.0.0") = await v2Updater.update() else {
            Issue.record("v3 did not install")
            return
        }
        let session = try updatedLater.updater.beginUpdateSession(operation: "test-rollback")
        defer { session.release() }
        #expect(throws: SelfUpdater.RollbackRefusal.changedSinceConfirmation(installed: "3.0.0", predecessor: "2.0.0")) {
            try updatedLater.updater.rollBackToPredecessor(session: session, plan: plan)
        }
        #expect(try updatedLater.liveRelease() == "3.0.0")
    }

    @Test("a rollback that fails after its journal was written is finished under the same lease")
    func failureIsFinishedUnderTheLease() async throws {
        struct InjectedFailure: Error {}
        let installed = try await InstalledUpdate.make(promote: true)
        defer { Task { await installed.shutdown() } }
        let once = OneShotFault()
        let failing = SelfUpdater(
            coordinatorBaseURL: installed.baseURL.absoluteString, installRoot: installed.fixture.installRoot,
            verifyCodeSignatures: false, currentVersion: "2.0.0",
            recoveryFaultInjector: { point in
                if point == .liveLayoutExchanged, once.claim() { throw InjectedFailure() }
            })

        let plan = try failing.rollbackPlan()
        let session = try failing.beginUpdateSession(operation: "test-rollback")
        defer { session.release() }
        #expect(try failing.rollBackToPredecessor(session: session, plan: plan) == "1.0.0")

        #expect(try installed.liveRelease() == "1.0.0")
        #expect(try installed.leftoverRollbackFiles().isEmpty)
        let state = try installed.store.loadState()
        #expect(state.current?.version == "1.0.0")
        #expect(state.quarantine?.version == "2.0.0")
        #expect(state.installGeneration == plan.generation)
    }
}
