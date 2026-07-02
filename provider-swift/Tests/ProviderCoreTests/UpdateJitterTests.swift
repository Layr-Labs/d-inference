/// Rollover-jitter tests: delay bounds (seeded RNG), the disabled/forced
/// bypasses, and the AutoUpdateController sequencing — the jitter must sit
/// strictly AFTER download/verify/stage (security checks undeferred, still
/// serving) and BEFORE the drain, and must never run on the no-update paths.

import Foundation
import Testing

@testable import ProviderCore

// MARK: - Deterministic RNG

/// SplitMix64 — tiny deterministic RNG for bound assertions.
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("UpdateJitter")
struct UpdateJitterTests {

    @Test("delays stay within [0, maxSeconds] and actually vary")
    func delayBounds() {
        var rng = SeededRNG(seed: 42)
        var seen = Set<Duration>()
        for _ in 0..<500 {
            let delay = UpdateJitter.delay(maxSeconds: 300, using: &rng)
            #expect(delay >= .zero)
            #expect(delay <= .seconds(300))
            seen.insert(delay)
        }
        // Uniform draws over 300_000 ms — a degenerate constant would defeat
        // the whole point of de-correlating fleet restarts.
        #expect(seen.count > 10)
    }

    @Test("update_jitter_seconds = 0 disables jitter")
    func zeroMaxDisables() {
        var rng = SeededRNG(seed: 7)
        #expect(UpdateJitter.delay(maxSeconds: 0, using: &rng) == .zero)
    }

    @Test("forced updates bypass jitter entirely")
    func forcedBypassesJitter() {
        var rng = SeededRNG(seed: 7)
        for _ in 0..<50 {
            #expect(UpdateJitter.delay(maxSeconds: 300, forced: true, using: &rng) == .zero)
        }
    }

    @Test("a misconfigured huge max is capped at one hour")
    func hugeMaxIsCapped() {
        var rng = SeededRNG(seed: 7)
        for _ in 0..<200 {
            let delay = UpdateJitter.delay(maxSeconds: .max, using: &rng)
            #expect(delay <= .seconds(UpdateJitter.maxJitterCapSeconds))
        }
    }
}

// MARK: - AutoUpdateController sequencing

@Suite("AutoUpdateController rollover jitter")
struct AutoUpdateJitterSequencingTests {

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

    private static let release = ReleaseInfo(
        version: "2.0.0",
        platform: "macos-arm64",
        url: "https://example.test/bundle.tar.gz",
        bundleHash: String(repeating: "a", count: 64)
    )

    private func makeController(
        checkResult: UpdateCheckResult,
        stageResult: AutoUpdateController.StepOutcome = .completed,
        recorder: Recorder
    ) -> AutoUpdateController {
        let deps = AutoUpdateController.Dependencies(
            claimStart: { recorder.record("claim"); return true },
            resumeServing: { recorder.record("resume") },
            check: { recorder.record("check"); return checkResult },
            downloadVerifyStage: { _ in recorder.record("stage"); return stageResult },
            waitBeforeInstall: { recorder.record("jitter") },
            beginDraining: { recorder.record("beginDraining") },
            waitForDrain: { _ in recorder.record("waitForDrain"); return true },
            forceCancelInflight: { recorder.record("forceCancel") },
            commitInstall: { recorder.record("commit"); return .completed },
            restart: { recorder.record("restart") },
            log: { _ in }
        )
        return AutoUpdateController(deps: deps, drainTimeout: .milliseconds(10))
    }

    @Test("jitter runs after the verified stage and before the drain")
    func jitterSitsBetweenStageAndDrain() async {
        let recorder = Recorder()
        let controller = makeController(
            checkResult: .updateAvailable(current: "1.0.0", latest: Self.release),
            recorder: recorder)

        let outcome = await controller.run()

        #expect(outcome == .restarted(from: "1.0.0", to: "2.0.0", drained: true))
        #expect(recorder.events == [
            "claim", "check", "stage", "jitter", "beginDraining",
            "waitForDrain", "commit", "restart",
        ])
    }

    @Test("no update available: jitter never runs")
    func upToDateSkipsJitter() async {
        let recorder = Recorder()
        let controller = makeController(
            checkResult: .upToDate(currentVersion: "1.0.0"),
            recorder: recorder)

        _ = await controller.run()

        #expect(!recorder.events.contains("jitter"))
    }

    @Test("failed stage: jitter never runs (nothing verified to install)")
    func stageFailureSkipsJitter() async {
        let recorder = Recorder()
        let controller = makeController(
            checkResult: .updateAvailable(current: "1.0.0", latest: Self.release),
            stageResult: .failed("disk full"),
            recorder: recorder)

        let outcome = await controller.run()

        #expect(outcome == .stageFailed("disk full"))
        #expect(!recorder.events.contains("jitter"))
        #expect(!recorder.events.contains("beginDraining"))
    }
}
