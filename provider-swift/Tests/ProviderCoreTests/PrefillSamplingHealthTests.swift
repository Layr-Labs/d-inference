import Foundation
import Testing

@testable import ProviderCore

/// Unit tests for the prefill-sample classifier (#1). Pins the EXACT bounds the
/// EWMA sampling uses so the health counters can never silently diverge from the
/// accept decision — and documents the window-collapse drop that strands the
/// prefill EWMA at 0.
@Suite("Prefill sampling health")
struct PrefillSamplingHealthTests {

    @Test func acceptsAColdSampleWithinBounds() {
        // 1000 tok over 0.5s = 2000 tok/s: above the 1ms floor, below the 8000 cap.
        let outcome = BatchScheduler.classifyPrefillSample(
            prefilledTokens: 1000, prefillSeconds: 0.5)
        #expect(outcome == .accepted(tps: 2000))
    }

    @Test func dropsBelowTheOneMillisecondFloor() {
        // A prefix-cache hit collapses the window (~0.5ms < 1ms floor): the
        // dominant reason the EWMA never initializes.
        let outcome = BatchScheduler.classifyPrefillSample(
            prefilledTokens: 1000, prefillSeconds: 0.0005)
        #expect(outcome == .belowFloor)
    }

    @Test func dropsAboveThePlausibilityCeiling() {
        // 1000 tok over 10ms = 100k tok/s: above the floor but past the 8000 cap.
        let outcome = BatchScheduler.classifyPrefillSample(
            prefilledTokens: 1000, prefillSeconds: 0.01)
        #expect(outcome == .aboveCeiling)
    }

    @Test func ignoresNonColdPrefill() {
        #expect(
            BatchScheduler.classifyPrefillSample(prefilledTokens: 0, prefillSeconds: 0.5)
                == .notColdPrefill)
    }

    @Test func rawSampleTpsReflectsTheCollapsedWindow() {
        // Below-floor sample still yields a (huge) raw rate — the diagnostic that
        // reveals the collapse next to a climbing droppedFloor count.
        let raw = BatchScheduler.rawPrefillSampleTps(
            prefilledTokens: 1000, prefillSeconds: 0.0005)
        #expect(raw == 2_000_000)
        // No rate computable for a non-cold or zero-window sample.
        #expect(BatchScheduler.rawPrefillSampleTps(prefilledTokens: 0, prefillSeconds: 0.5) == nil)
        #expect(BatchScheduler.rawPrefillSampleTps(prefilledTokens: 10, prefillSeconds: 0) == nil)
    }

    @Test func healthStartsEmpty() {
        let h = PrefillSamplingHealth()
        #expect(h.accepted == 0)
        #expect(h.droppedFloor == 0)
        #expect(h.droppedCeiling == 0)
        #expect(h.lastSampleTps == 0)
    }
}
