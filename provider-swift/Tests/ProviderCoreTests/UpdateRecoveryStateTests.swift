import Foundation
import Testing
@testable import ProviderCore

@Suite("Update recovery state")
struct UpdateRecoveryStateTests {
    @Test("failed start is counted once per armed attempt")
    func countsOneFailurePerAttempt() {
        var state = makeCandidateState()
        let firstFailure = state.recordPendingAttemptFailure(now: 100)
        let duplicateTick = state.recordPendingAttemptFailure(now: 101)
        #expect(firstFailure == 1)
        #expect(duplicateTick == nil)
        #expect(state.candidate?.failureCount == 1)

        let armed = state.armCandidateAttempt(now: 200)
        let secondFailure = state.recordPendingAttemptFailure(now: 201)
        let secondDuplicate = state.recordPendingAttemptFailure(now: 202)
        #expect(armed)
        #expect(secondFailure == 2)
        #expect(secondDuplicate == nil)
    }

    @Test("continuous healthy heartbeat promotes and clears failure state")
    func successfulStartPromotes() {
        var state = makeCandidateState(failures: 2)
        let first = state.observeCandidateHealth(
            healthySignal: true,
            processStartedAt: 10,
            now: 100,
            stabilizationSeconds: 60
        )
        let stale = state.observeCandidateHealth(
            healthySignal: false,
            processStartedAt: nil,
            now: 130,
            stabilizationSeconds: 60
        )
        let restarted = state.observeCandidateHealth(
            healthySignal: true,
            processStartedAt: 20,
            now: 200,
            stabilizationSeconds: 60
        )
        let promoted = state.observeCandidateHealth(
            healthySignal: true,
            processStartedAt: 20,
            now: 261,
            stabilizationSeconds: 60
        )
        #expect(!first)
        #expect(!stale)
        #expect(!restarted)
        #expect(promoted)
        #expect(state.candidate == nil)
        #expect(state.current?.version == "2.0.0")
        #expect(state.predecessor?.release.version == "1.0.0")
    }

    @Test("new daemon process restarts stabilization window")
    func processIdentityRestartsWindow() {
        var state = makeCandidateState()
        _ = state.observeCandidateHealth(
            healthySignal: true,
            processStartedAt: 10,
            now: 100,
            stabilizationSeconds: 60
        )
        let newProcess = state.observeCandidateHealth(
            healthySignal: true,
            processStartedAt: 150,
            now: 159,
            stabilizationSeconds: 60
        )
        let tooSoon = state.observeCandidateHealth(
            healthySignal: true,
            processStartedAt: 150,
            now: 218,
            stabilizationSeconds: 60
        )
        let promoted = state.observeCandidateHealth(
            healthySignal: true,
            processStartedAt: 150,
            now: 220,
            stabilizationSeconds: 60
        )
        #expect(!newProcess)
        #expect(!tooSoon)
        #expect(promoted)
    }

    @Test("quarantine blocks exact bad version but not a newer release")
    func quarantineAllowsNewerEscape() {
        var state = makeCandidateState(failures: 3)
        state.completeRollback(now: 500, reason: "three failed starts")

        #expect(state.quarantineBlocks(version: "2.0.0", manualOverride: false))
        #expect(!state.quarantineBlocks(version: "3.0.0", manualOverride: false))
        #expect(!state.quarantineBlocks(version: "2.0.0", manualOverride: true))
        #expect(state.current?.version == "1.0.0")
        #expect(state.candidate == nil)
    }

    @Test("rollback failure uses bounded exponential retry")
    func rollbackFailureBackoff() {
        var state = makeCandidateState(failures: 3)
        state.deferRetryAfterRollbackFailure(now: 1_000, reason: "corrupt predecessor")
        #expect(state.candidate?.retryNotBefore == 1_300)
        #expect(state.isCandidateRetryBackedOff(now: 1_299))
        #expect(!state.isCandidateRetryBackedOff(now: 1_300))

        state.candidate?.failureCount = 7
        state.deferRetryAfterRollbackFailure(now: 2_000, reason: "still corrupt")
        #expect(state.candidate?.retryNotBefore == 5_600)
    }

    private func makeCandidateState(failures: Int = 0) -> UpdateRecoveryState {
        let predecessorRecord = InstalledReleaseRecord(
            version: "1.0.0",
            releaseBundleHash: "release-old",
            installedBundleHash: "bundle-old",
            binaryHash: "binary-old",
            metallibHash: "metallib-old",
            installGeneration: 0,
            installedAt: 1
        )
        let predecessor = VerifiedPredecessor(
            release: predecessorRecord,
            layout: .app,
            bundlePath: "predecessor/Darkbloom.app",
            binaryPath: "predecessor/Darkbloom.app/Contents/MacOS/darkbloom",
            metallibPath: "predecessor/Darkbloom.app/Contents/MacOS/mlx.metallib",
            verifiedAt: 2
        )
        let candidateRecord = InstalledReleaseRecord(
            version: "2.0.0",
            releaseBundleHash: "release-new",
            installedBundleHash: "bundle-new",
            binaryHash: "binary-new",
            metallibHash: "metallib-new",
            installGeneration: 1,
            installedAt: 3
        )
        return UpdateRecoveryState(
            installGeneration: 1,
            current: predecessorRecord,
            candidate: PendingReleaseCandidate(
                release: candidateRecord,
                failureCount: failures,
                pendingAttemptID: "attempt",
                attemptStartedAt: 4,
                healthySince: nil,
                healthyProcessStartedAt: nil,
                retryNotBefore: nil,
                rollbackBlockedReason: nil
            ),
            predecessor: predecessor
        )
    }
}
