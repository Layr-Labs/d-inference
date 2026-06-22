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

    @Test func notSuspectedBelowConsecutiveThreshold() {
        var m = WedgeMonitor()
        // Two admits (< 3) even after a long stall must NOT trip.
        m.recordAdmit(now: base)
        m.recordAdmit(now: base)
        #expect(m.wedgeSuspected(now: base.advanced(by: .seconds(60))) == false)
    }

    @Test func notSuspectedBelowStallSeconds() {
        var m = WedgeMonitor()
        for _ in 0..<WedgeMonitor.suspectConsecutiveAdmits {
            m.recordAdmit(now: base)
        }
        // Threshold count met, but the streak is younger than T seconds.
        #expect(m.wedgeSuspected(now: base.advanced(by: .seconds(9))) == false)
    }

    @Test func suspectedWhenAdmitsStallPastThreshold() {
        var m = WedgeMonitor()
        for _ in 0..<WedgeMonitor.suspectConsecutiveAdmits {
            m.recordAdmit(now: base)
        }
        // ≥ N admits AND the dry streak has lasted ≥ T seconds → wedge suspected.
        #expect(m.wedgeSuspected(now: base.advanced(by: .seconds(11))) == true)
        #expect(m.dryStreakSeconds(now: base.advanced(by: .seconds(11))) == 11)
    }

    @Test func firstTokenClearsSuspicion() {
        var m = WedgeMonitor()
        for _ in 0..<WedgeMonitor.suspectConsecutiveAdmits {
            m.recordAdmit(now: base)
        }
        #expect(m.wedgeSuspected(now: base.advanced(by: .seconds(11))) == true)

        // A real first token resets the streak — the box recovered.
        m.recordFirstToken(now: base.advanced(by: .seconds(11)))
        #expect(m.wedgeSuspected(now: base.advanced(by: .seconds(30))) == false)
        #expect(m.secondsSinceLastFirstToken(now: base.advanced(by: .seconds(13))) == 2)
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
}
