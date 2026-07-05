import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Adaptive prefill runtime — sample plumbing + migration")
struct AdaptivePrefillRuntimeTests {
    private let ladder = [512, 1024, 1536, 2048]

    private func tempStore() -> AdaptivePrefillStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("adaptive-prefill-rt-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("state.json")
        return AdaptivePrefillStore(url: url)
    }

    private func key() -> AdaptivePrefillStoreKey {
        AdaptivePrefillStoreKey(
            modelId: "m", weightIdentity: "w", kvMode: "fp16", hardwareMemoryFingerprint: "h")
    }

    private func policy(initial: Int? = nil, ladder: [Int]? = nil) -> AdaptivePrefillPolicy {
        AdaptivePrefillPolicy(
            ladder: ladder ?? self.ladder, initialChunkSize: initial,
            minCleanSamplesPerRung: 2, cooldownSampleCount: 1)
    }

    private let normalSafety: AdaptivePrefillRuntime.SafetySignalProvider = { (.normal, .nominal) }

    /// Clean first-chunk cold sample at `rung` with the given ms/token.
    private func cleanCold(_ rung: Int, msPerToken: Double, positionOffset: Int = 0)
        -> ColdPrefillChunkSample {
        ColdPrefillChunkSample(
            requestedChunkSize: rung, actualChunkSize: rung, batchSize: 1,
            totalTokens: rung, positionOffset: positionOffset,
            durationSeconds: msPerToken * Double(rung) / 1000.0,
            decodeBatchSize: 0, cappedByBudget: false,
            cappedByCheckpoint: false, cappedByRemaining: false)
    }

    /// A cold-prefill chunk that overlaps an active decode step, with an explicit
    /// wall-time (the quantity that stalls the concurrent decode tokens).
    private func overlapCold(
        _ rung: Int, durationMs: Double, decodeBatchSize: Int = 4, positionOffset: Int = 0
    ) -> ColdPrefillChunkSample {
        ColdPrefillChunkSample(
            requestedChunkSize: rung, actualChunkSize: rung, batchSize: 1,
            totalTokens: rung, positionOffset: positionOffset,
            durationSeconds: durationMs / 1000.0,
            decodeBatchSize: decodeBatchSize, cappedByBudget: false,
            cappedByCheckpoint: false, cappedByRemaining: false)
    }

    @Test("clean cold samples flow through and converge on the U-curve minimum")
    func convergesThroughRuntime() {
        let runtime = AdaptivePrefillRuntime(
            policy: policy(initial: 512), store: tempStore(), key: key(),
            safetySignalProvider: normalSafety)
        let curve = [512: 3.0, 1024: 2.0, 1536: 1.0, 2048: 2.0]
        for _ in 0..<40 {
            let rung = runtime.snapshotState().currentChunkSize
            runtime.record(cleanCold(rung, msPerToken: curve[rung] ?? 9))
        }
        #expect(runtime.snapshotState().currentChunkSize == 1536)
    }

    @Test("positionOffset > 0 cold samples never move the ladder")
    func positionOffsetIgnoredThroughRuntime() {
        let runtime = AdaptivePrefillRuntime(
            policy: policy(initial: 1024), store: tempStore(), key: key(),
            safetySignalProvider: normalSafety)
        for _ in 0..<30 {
            // Later-chunk samples (positionOffset > 0) at an ever-faster ms/token —
            // they must be ignored so O(N²) drift can't drive the ladder.
            runtime.record(cleanCold(1024, msPerToken: 0.1, positionOffset: 1024))
        }
        #expect(runtime.snapshotState().currentChunkSize == 1024)
        #expect(runtime.snapshotState().rungMsPerToken.isEmpty)
    }

    @Test("injected memory pressure forces an immediate back-off")
    func harmBacksOffThroughRuntime() {
        let highMemory: AdaptivePrefillRuntime.SafetySignalProvider = { (.high, .nominal) }
        let runtime = AdaptivePrefillRuntime(
            policy: policy(initial: 2048, ladder: [512, 1024, 2048, 4096]),
            store: tempStore(), key: key(), safetySignalProvider: highMemory)
        runtime.record(cleanCold(2048, msPerToken: 1.0))
        let state = runtime.snapshotState()
        #expect(state.currentChunkSize == 1024)
        #expect(state.lastDecisionReason == .shrinkMemoryPressure)
    }

    // MARK: - Decode-latency harm wiring

    @Test("a slow overlapped chunk trips decode-latency harm: shrink one rung + lock ceiling")
    func decodeHarmShrinksThroughRuntime() {
        let runtime = AdaptivePrefillRuntime(
            policy: policy(initial: 2048, ladder: [512, 1024, 2048, 4096]),
            store: tempStore(), key: key(),
            safetySignalProvider: normalSafety,
            decodeOverlapHarmBudgetMs: 250.0)
        // 600ms overlapped first chunk ≫ 250ms budget ⇒ materially stalls decode.
        runtime.record(overlapCold(2048, durationMs: 600))
        let state = runtime.snapshotState()
        #expect(state.currentChunkSize == 1024)            // one rung down
        #expect(state.lastDecisionReason == .shrinkDecodeHarm)
        #expect(state.ceiling == 1024)                     // ceiling locked
    }

    @Test("a fast overlapped chunk is normal overlap, not harm (no false positive)")
    func decodeOverlapNoFalsePositive() {
        let runtime = AdaptivePrefillRuntime(
            policy: policy(initial: 2048, ladder: [512, 1024, 2048, 4096]),
            store: tempStore(), key: key(),
            safetySignalProvider: normalSafety,
            decodeOverlapHarmBudgetMs: 250.0)
        // 100ms overlapped chunk < 250ms budget ⇒ ordinary overlap; stays put.
        runtime.record(overlapCold(2048, durationMs: 100))
        let state = runtime.snapshotState()
        #expect(state.currentChunkSize == 2048)
        #expect(state.lastDecisionReason != .shrinkDecodeHarm)
    }

    @Test("a slow LATE overlapped chunk does not trip harm (position cost, not chunk size)")
    func decodeHarmIgnoresLateChunks() {
        let runtime = AdaptivePrefillRuntime(
            policy: policy(initial: 2048, ladder: [512, 1024, 2048, 4096]),
            store: tempStore(), key: key(),
            safetySignalProvider: normalSafety,
            decodeOverlapHarmBudgetMs: 250.0)
        // Slow AND overlapped, but positionOffset > 0 ⇒ the cost is O(N²) attention
        // growth, not an oversized rung — must not collapse the ladder to the floor.
        runtime.record(overlapCold(2048, durationMs: 600, positionOffset: 4096))
        let state = runtime.snapshotState()
        #expect(state.currentChunkSize == 2048)
        #expect(state.lastDecisionReason != .shrinkDecodeHarm)
    }

    // MARK: - Migration

    @Test("a current-version persisted rung is restored on construction")
    func restoresCurrentVersionState() throws {
        let store = tempStore()
        let k = key()
        try store.save(
            AdaptivePrefillState(
                currentChunkSize: 1024,
                policyVersion: AdaptivePrefillPolicy.algorithmIdentity),
            key: k)
        let runtime = AdaptivePrefillRuntime(
            policy: policy(initial: 1536), store: store, key: k,
            safetySignalProvider: normalSafety)
        #expect(runtime.snapshotState().currentChunkSize == 1024)
    }

    @Test("a stale policyVersion persisted rung is discarded and re-seeded")
    func reseedsStalePolicyVersion() throws {
        let store = tempStore()
        let k = key()
        try store.save(
            AdaptivePrefillState(currentChunkSize: 2048, policyVersion: "duration.v1"),
            key: k)
        let runtime = AdaptivePrefillRuntime(
            policy: policy(initial: 1536), store: store, key: k,
            safetySignalProvider: normalSafety)
        // Stale state ignored → falls back to the policy's roofline seed.
        #expect(runtime.snapshotState().currentChunkSize == 1536)
    }
}
