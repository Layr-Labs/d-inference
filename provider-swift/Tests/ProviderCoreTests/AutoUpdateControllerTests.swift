import Foundation
import Testing
@testable import ProviderCore

/// Tests for the graceful auto-update sequencing. The whole value of
/// `AutoUpdateController` is the ORDER of side effects and which ones happen on
/// each path, so these assert the recorded call order against fakes — no
/// network, filesystem, or launchd involved.
@Suite("AutoUpdateController")
struct AutoUpdateControllerTests {

    /// Thread-safe ordered recorder. A plain locked class (not an actor) so the
    /// non-async `restart` closure can record too.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [String] = []
        func record(_ event: String) {
            lock.lock(); _events.append(event); lock.unlock()
        }
        var events: [String] {
            lock.lock(); defer { lock.unlock() }; return _events
        }
    }

    private enum FakeError: Error { case restart }

    /// Knobs controlling the fake collaborators' return values.
    private struct Fakes {
        var claimReturns = true
        var checkResult: UpdateCheckResult
        var stageResult: AutoUpdateController.StepOutcome = .completed
        var commitResult: AutoUpdateController.StepOutcome = .completed
        var drainReturns = true
        var restartThrows = false
    }

    private static let release = ReleaseInfo(
        version: "2.0.0",
        platform: "macos-arm64",
        url: "https://example.test/bundle.tar.gz",
        bundleHash: String(repeating: "a", count: 64)
    )

    private func makeController(
        _ fakes: Fakes,
        recorder: Recorder,
        drainTimeout: Duration = .milliseconds(10)
    ) -> AutoUpdateController {
        let deps = AutoUpdateController.Dependencies(
            claimStart: { recorder.record("claim"); return fakes.claimReturns },
            resumeServing: { recorder.record("resume") },
            check: { recorder.record("check"); return fakes.checkResult },
            downloadVerifyStage: { _ in recorder.record("stage"); return fakes.stageResult },
            beginDraining: { recorder.record("beginDraining") },
            waitForDrain: { _ in recorder.record("waitForDrain"); return fakes.drainReturns },
            forceCancelInflight: { recorder.record("forceCancel") },
            commitInstall: { recorder.record("commit"); return fakes.commitResult },
            restart: {
                recorder.record("restart")
                if fakes.restartThrows { throw FakeError.restart }
            },
            log: { _ in }
        )
        return AutoUpdateController(deps: deps, drainTimeout: drainTimeout)
    }

    // MARK: - No-op paths

    @Test("re-entrancy: a second cycle while one is underway does nothing")
    func reentrancyIsNoOp() async {
        let recorder = Recorder()
        var fakes = Fakes(checkResult: .upToDate(currentVersion: "1.0.0"))
        fakes.claimReturns = false
        let controller = makeController(fakes, recorder: recorder)

        let outcome = await controller.run()

        #expect(outcome == .alreadyRunning)
        // Claim failed → nothing else runs, and crucially we never reset the
        // phase (the in-progress cycle owns it).
        #expect(recorder.events == ["claim"])
    }

    @Test("up to date: checks then resumes serving, no drain or restart")
    func upToDateResumesServing() async {
        let recorder = Recorder()
        let controller = makeController(
            Fakes(checkResult: .upToDate(currentVersion: "1.0.0")),
            recorder: recorder
        )

        let outcome = await controller.run()

        #expect(outcome == .upToDate)
        #expect(recorder.events == ["claim", "check", "resume"])
    }

    @Test("check failure: resumes serving, never drains")
    func checkFailureResumesServing() async {
        let recorder = Recorder()
        let controller = makeController(
            Fakes(checkResult: .checkFailed(reason: "network down")),
            recorder: recorder
        )

        let outcome = await controller.run()

        #expect(outcome == .checkFailed("network down"))
        #expect(recorder.events == ["claim", "check", "resume"])
    }

    // MARK: - The critical invariant: a failed download/stage never drains

    @Test("download/stage failure: stays serving, NEVER drains, commits, or restarts")
    func stageFailureNeverDrains() async {
        let recorder = Recorder()
        var fakes = Fakes(checkResult: .updateAvailable(current: "1.0.0", latest: Self.release))
        fakes.stageResult = .failed("disk full")
        let controller = makeController(fakes, recorder: recorder)

        let outcome = await controller.run()

        #expect(outcome == .stageFailed("disk full"))
        // No beginDraining, no waitForDrain, no commit, no restart — a botched
        // update must not cost serving capacity.
        #expect(recorder.events == ["claim", "check", "stage", "resume"])
        #expect(!recorder.events.contains("beginDraining"))
        #expect(!recorder.events.contains("commit"))
        #expect(!recorder.events.contains("restart"))
    }

    // MARK: - Happy path: stage → drain → commit → restart

    @Test("success with clean drain: stage while serving, drain, commit AFTER drain, then restart")
    func successDrainsThenCommitsThenRestarts() async {
        let recorder = Recorder()
        let controller = makeController(
            Fakes(checkResult: .updateAvailable(current: "1.0.0", latest: Self.release)),
            recorder: recorder
        )

        let outcome = await controller.run()

        #expect(outcome == .restarted(from: "1.0.0", to: "2.0.0", drained: true))
        // Strict order: download/stage happens BEFORE we stop accepting work,
        // and the live-layout commit happens strictly AFTER the drain so no
        // request can observe a half-replaced bundle.
        #expect(recorder.events == ["claim", "check", "stage", "beginDraining", "waitForDrain", "commit", "restart"])
        #expect(!recorder.events.contains("forceCancel"))
        #expect(!recorder.events.contains("resume")) // restart succeeded → no resume
    }

    @Test("drain timeout: force-cancels stragglers, then commits and restarts anyway")
    func drainTimeoutForceCancels() async {
        let recorder = Recorder()
        var fakes = Fakes(checkResult: .updateAvailable(current: "1.0.0", latest: Self.release))
        fakes.drainReturns = false
        let controller = makeController(fakes, recorder: recorder)

        let outcome = await controller.run()

        #expect(outcome == .restarted(from: "1.0.0", to: "2.0.0", drained: false))
        #expect(recorder.events == ["claim", "check", "stage", "beginDraining", "waitForDrain", "forceCancel", "commit", "restart"])
    }

    @Test("commit failure: resumes serving on the old binary, never restarts")
    func commitFailureResumes() async {
        let recorder = Recorder()
        var fakes = Fakes(checkResult: .updateAvailable(current: "1.0.0", latest: Self.release))
        fakes.commitResult = .failed("rename failed")
        let controller = makeController(fakes, recorder: recorder)

        let outcome = await controller.run()

        #expect(outcome == .commitFailed("rename failed"))
        #expect(recorder.events == ["claim", "check", "stage", "beginDraining", "waitForDrain", "commit", "resume"])
        #expect(!recorder.events.contains("restart"))
    }

    @Test("restart failure: resumes serving on the old binary")
    func restartFailureResumes() async {
        let recorder = Recorder()
        var fakes = Fakes(checkResult: .updateAvailable(current: "1.0.0", latest: Self.release))
        fakes.restartThrows = true
        let controller = makeController(fakes, recorder: recorder)

        let outcome = await controller.run()

        guard case .restartFailed = outcome else {
            Issue.record("expected .restartFailed, got \(outcome)")
            return
        }
        #expect(recorder.events == ["claim", "check", "stage", "beginDraining", "waitForDrain", "commit", "restart", "resume"])
    }
}
