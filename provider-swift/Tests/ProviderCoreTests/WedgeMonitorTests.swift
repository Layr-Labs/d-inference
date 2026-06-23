import Foundation
import Testing

@testable import ProviderCore

/// Unit tests for `WedgeMonitor` — the pure, MEASUREMENT-ONLY engine-health
/// accounting that confirms the first-token wedge
/// (docs/reports/2026-06-22-cancel-root-cause-and-fix.md §C). Time is injected
/// via explicit `ContinuousClock.Instant`s so the threshold logic is
/// deterministic without sleeping.
@Suite("WedgeMonitor")
struct WedgeMonitorTests {

    private let base = ContinuousClock.now

    @Test func countersTrackAdmitsAndFirstTokens() {
        var m = WedgeMonitor()
        m.recordAdmit(now: base)
        m.recordAdmit(now: base)
        #expect(m.admits == 2)
        #expect(m.firstTokens == 0)
        #expect(m.consecutiveAdmitsWithoutFirstToken == 2)

        m.recordFirstToken(now: base)
        #expect(m.firstTokens == 1)
        #expect(m.consecutiveAdmitsWithoutFirstToken == 0)
    }

    /// Seed N hanging admits with the engine step counter FROZEN at `base`
    /// (sampled once, never advanced) — the full wedge setup. Steps then read as
    /// frozen for `now - base` seconds.
    private func frozenHangingMonitor() -> WedgeMonitor {
        var m = WedgeMonitor()
        for _ in 0..<WedgeMonitor.suspectConsecutiveAdmits {
            m.recordAdmit(now: base)
        }
        m.sampleSteps(100, now: base)
        return m
    }

    @Test func notSuspectedBelowConsecutiveThreshold() {
        var m = WedgeMonitor()
        // Two admits (< 3) with steps frozen + a long stall must NOT trip.
        m.recordAdmit(now: base)
        m.recordAdmit(now: base)
        m.sampleSteps(100, now: base)
        #expect(m.wedgeSuspected(now: base.advanced(by: .seconds(60))) == false)
    }

    @Test func notSuspectedBelowStallSeconds() {
        var m = frozenHangingMonitor()
        // Count + frozen steps, but the streak is younger than T seconds.
        #expect(m.wedgeSuspected(now: base.advanced(by: .seconds(9))) == false)
    }

    @Test func suspectedWhenAdmitsStallAndStepsFrozen() {
        let m = frozenHangingMonitor()
        // ≥ N hanging admits, streak ≥ T, AND steps frozen ≥ T → wedge suspected.
        #expect(m.wedgeSuspected(now: base.advanced(by: .seconds(11))) == true)
        #expect(m.dryStreakSeconds(now: base.advanced(by: .seconds(11))) == 11)
    }

    /// Fix 1 regression: 3 slow prefills (>10 s, 0 first tokens) whose engine
    /// step counter is STILL ADVANCING are a slow batch, NOT a wedge — must not
    /// trip. Only when steps also flatline does it become a wedge.
    @Test func notSuspectedWhenStepsAdvancing() {
        var m = WedgeMonitor()
        for _ in 0..<WedgeMonitor.suspectConsecutiveAdmits {
            m.recordAdmit(now: base)
        }
        // Steps keep advancing — sampled fresh each time, so never frozen.
        m.sampleSteps(100, now: base)
        m.sampleSteps(150, now: base.advanced(by: .seconds(11)))
        // Streak ≥ 10 and count ≥ 3, but steps advanced 0 s ago ⇒ NOT suspected.
        #expect(m.wedgeSuspected(now: base.advanced(by: .seconds(11))) == false)

        // Now the steps freeze (same value): 11 s later it IS a wedge.
        m.sampleSteps(150, now: base.advanced(by: .seconds(22)))
        #expect(m.wedgeSuspected(now: base.advanced(by: .seconds(22))) == true)
    }

    @Test func firstTokenClearsSuspicion() {
        var m = frozenHangingMonitor()
        #expect(m.wedgeSuspected(now: base.advanced(by: .seconds(11))) == true)

        // A real first token resets the streak — the box recovered.
        m.recordFirstToken(now: base.advanced(by: .seconds(11)))
        #expect(m.wedgeSuspected(now: base.advanced(by: .seconds(30))) == false)
        #expect(m.secondsSinceLastFirstToken(now: base.advanced(by: .seconds(13))) == 2)
    }

    /// Fix 2 regression: admits that terminate with 0 tokens (client_gone
    /// cancels) must leave the hanging streak — they must NOT accumulate into a
    /// false wedge on a healthy box. A genuinely hung admit still trips.
    @Test func terminalWithoutFirstTokenClearsStreak() {
        var m = frozenHangingMonitor()
        #expect(m.wedgeSuspected(now: base.advanced(by: .seconds(11))) == true)

        // All three admits cancel before a first token → streak drains to 0.
        for _ in 0..<WedgeMonitor.suspectConsecutiveAdmits {
            m.recordTerminalWithoutFirstToken()
        }
        #expect(m.consecutiveAdmitsWithoutFirstToken == 0)
        #expect(m.wedgeSuspected(now: base.advanced(by: .seconds(30))) == false)

        // A fresh batch of genuinely-hung admits (no terminal) still trips, with
        // steps still frozen from `base`.
        for _ in 0..<WedgeMonitor.suspectConsecutiveAdmits {
            m.recordAdmit(now: base.advanced(by: .seconds(30)))
        }
        #expect(m.wedgeSuspected(now: base.advanced(by: .seconds(41))) == true)
    }

    @Test func sampleStepsTracksFlatline() {
        var m = WedgeMonitor()
        m.sampleSteps(100, now: base)
        // No advance: same step count 5s later → 5s since last step.
        m.sampleSteps(100, now: base.advanced(by: .seconds(5)))
        #expect(m.secondsSinceLastStep(now: base.advanced(by: .seconds(5))) == 5)

        // Advance: step counter moved → clock resets.
        m.sampleSteps(101, now: base.advanced(by: .seconds(6)))
        #expect(m.lastStepsSample == 101)
        #expect(m.secondsSinceLastStep(now: base.advanced(by: .seconds(6))) == 0)
    }

    @Test func resetClearsState() {
        var m = WedgeMonitor()
        for _ in 0..<5 { m.recordAdmit(now: base) }
        m.sampleSteps(42, now: base)
        m.reset()
        #expect(m.admits == 0)
        #expect(m.firstTokens == 0)
        #expect(m.consecutiveAdmitsWithoutFirstToken == 0)
        #expect(m.lastStepsSample == 0)
        #expect(m.wedgeSuspected(now: base.advanced(by: .seconds(60))) == false)
    }

    /// B1 regression: after an older admit ends (terminal w/o first token), the
    /// dry-streak must re-anchor to the OLDEST still-hanging admit — not to the
    /// admit that already ended. Codex scenario: A@0, B/C@9, A cancels@9.5, D@10,
    /// steps frozen ⇒ NOT a wedge (B/C/D have only stalled ~1s). Pre-fix the
    /// anchor stayed at the ended A@0 and falsely reported a wedge at t=10.
    @Test func dryStreakAnchorsToOldestStillHangingAdmit() {
        var m = WedgeMonitor()
        m.sampleSteps(100, now: base)  // frozen baseline (steps never advance)
        m.recordAdmit(now: base)  // A@0
        m.recordAdmit(now: base.advanced(by: .seconds(9)))  // B@9
        m.recordAdmit(now: base.advanced(by: .seconds(9)))  // C@9
        m.recordTerminalWithoutFirstToken()  // A cancels (removes oldest, A@0)
        m.recordAdmit(now: base.advanced(by: .seconds(10)))  // D@10

        #expect(m.consecutiveAdmitsWithoutFirstToken == 3)  // B, C, D hanging
        // Oldest hanging is B@9 → only ~1s stalled at t=10 ⇒ NOT a wedge.
        #expect(m.wedgeSuspected(now: base.advanced(by: .seconds(10))) == false)
        // Once B/C/D actually stall ≥10s (B@9 → 10.5s) it IS a wedge.
        #expect(m.wedgeSuspected(now: base.advanced(by: .seconds(19.5))) == true)
    }

    /// B3 regression: a wedge callback from a bridge whose load was superseded by
    /// a reset (which bumps `generationEpoch` + resets the monitor) must be
    /// ignored, so a stale in-flight request can't corrupt the fresh model's
    /// counters. Exercises the epoch guard on `BatchScheduler.recordWedge*`.
    @Test func staleEpochWedgeCallbackIgnoredAfterReset() async {
        let s = BatchScheduler()
        let epoch0 = await s.generationEpoch
        await s.recordWedgeAdmit(epoch: epoch0)
        #expect(await s.wedgeMonitor.admits == 1)

        // A reload (unloadModel → stopCurrentEngine) bumps the epoch + resets.
        await s.unloadModel()
        #expect(await s.wedgeMonitor.admits == 0)

        // Stale callback at the OLD epoch is dropped — fresh monitor untouched.
        await s.recordWedgeAdmit(epoch: epoch0)
        #expect(await s.wedgeMonitor.admits == 0)

        // A current-epoch callback still records normally.
        let epoch1 = await s.generationEpoch
        await s.recordWedgeAdmit(epoch: epoch1)
        #expect(await s.wedgeMonitor.admits == 1)
    }
}
