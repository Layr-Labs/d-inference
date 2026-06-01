import Foundation
import Testing
@testable import MLXLMCommon

// Pure planner that boundary-aligns prefill chunks so a checkpoint snapshot
// can be taken exactly when the prefilled count lands on a checkpoint
// boundary. No model needed.

@Suite("CheckpointPrefillPlanner boundary alignment")
struct CheckpointPrefillPlannerTests {

    private func plan(_ prefilled: Int, _ chunk: Int, _ remaining: Int, _ b: [Int])
        -> CheckpointPrefillPlanner.Step
    {
        CheckpointPrefillPlanner.plan(
            prefilled: prefilled, defaultChunk: chunk, remaining: remaining, boundaries: b)
    }

    @Test("caps the chunk so it lands exactly on the next boundary, and captures there")
    func capsToBoundary() {
        // At 0, default chunk 512, boundary 256 ahead → cap to 256 + capture.
        let s = plan(0, 512, 1000, [256, 512])
        #expect(s.chunk == 256)
        #expect(s.captureAt == 256)
    }

    @Test("never grows the chunk; far boundary → default chunk, no capture")
    func farBoundaryKeepsDefault() {
        // Boundary 256 is farther than the default chunk 64 → take 64, no
        // capture yet (we step toward the boundary over multiple calls).
        let s = plan(0, 64, 1000, [256])
        #expect(s.chunk == 64)
        #expect(s.captureAt == nil)
    }

    @Test("captures when a later step finally reaches the boundary")
    func reachesBoundaryLater() {
        // 192 prefilled, default 64, boundary 256 → 64 lands exactly on 256.
        let s = plan(192, 64, 1000, [256])
        #expect(s.chunk == 64)
        #expect(s.captureAt == 256)
    }

    @Test("does not overshoot: chunk capped to remaining and to boundary")
    func neverOvershoots() {
        // Only 100 tokens remain; boundary 256 unreachable this prompt.
        let s = plan(0, 512, 100, [256, 512])
        #expect(s.chunk == 100)
        #expect(s.captureAt == nil, "boundary beyond the prompt is never captured")
    }

    @Test("no boundaries / none reachable → plain default chunk, no capture")
    func noBoundaries() {
        #expect(plan(0, 128, 1000, []).captureAt == nil)
        #expect(plan(0, 128, 1000, []).chunk == 128)
        // Boundary already passed.
        #expect(plan(300, 128, 1000, [256]).captureAt == nil)
    }

    @Test("multiple boundaries: targets the nearest one ahead")
    func nearestBoundary() {
        // At 256 already, next reachable is 512.
        let s = plan(256, 1024, 1000, [256, 512, 1024])
        #expect(s.chunk == 256)  // 512 - 256
        #expect(s.captureAt == 512)
    }

    @Test("chunk is always >= 1 even at degenerate inputs")
    func alwaysPositive() {
        #expect(plan(0, 0, 0, [256]).chunk >= 1)
        #expect(plan(0, 1, 1, [1]).chunk == 1)
        #expect(plan(0, 1, 1, [1]).captureAt == 1)
    }
}
