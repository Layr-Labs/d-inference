import Foundation
import Testing
@testable import ProviderCore

// Round-trip tests for the continuous-batching composition control vector.
// This is the protocol every rank uses to agree on the per-step batch
// composition; an encode/decode mismatch would silently desync the ring caches,
// so it is the highest-value thing to pin down with a unit test.

@Test func compositionRoundTripStep() {
    let comp = ClusterBatchComposition(
        command: .step,
        bNext: 5,
        keepIndices: [0, 2, 3],
        admit: [
            ClusterAdmitRow(promptTokens: [10, 11, 12], leftPadding: 0, maxTokens: 64),
            ClusterAdmitRow(promptTokens: [99], leftPadding: 2, maxTokens: 128),
        ])
    let decoded = ClusterBatchComposition.decode(comp.encodeVector())

    #expect(decoded.command == .step)
    #expect(decoded.bNext == 5)
    #expect(decoded.keepIndices == [0, 2, 3])
    #expect(decoded.admit.count == 2)
    #expect(decoded.admit[0].promptTokens == [10, 11, 12])
    #expect(decoded.admit[0].leftPadding == 0)
    #expect(decoded.admit[0].maxTokens == 64)
    #expect(decoded.admit[1].promptTokens == [99])
    #expect(decoded.admit[1].leftPadding == 2)
    #expect(decoded.admit[1].maxTokens == 128)
}

@Test func compositionRoundTripEvictOnly() {
    // A pure decode step: survivors only, nothing admitted.
    let comp = ClusterBatchComposition(
        command: .step, bNext: 2, keepIndices: [1, 4], admit: [])
    let decoded = ClusterBatchComposition.decode(comp.encodeVector())
    #expect(decoded.keepIndices == [1, 4])
    #expect(decoded.admit.isEmpty)
    #expect(decoded.bNext == 2)
}

@Test func compositionRoundTripAdmitOnly() {
    // Cold start: no survivors, first batch admitted.
    let comp = ClusterBatchComposition(
        command: .step, bNext: 1, keepIndices: [],
        admit: [ClusterAdmitRow(promptTokens: [1, 2, 3, 4, 5], leftPadding: 0, maxTokens: 32)])
    let decoded = ClusterBatchComposition.decode(comp.encodeVector())
    #expect(decoded.keepIndices.isEmpty)
    #expect(decoded.admit.count == 1)
    #expect(decoded.admit[0].promptTokens == [1, 2, 3, 4, 5])
}

@Test func compositionShutdownAndIdle() {
    let s = ClusterBatchComposition.decode(ClusterBatchComposition.shutdown.encodeVector())
    #expect(s.command == .shutdown)
    let i = ClusterBatchComposition.decode(ClusterBatchComposition.idle.encodeVector())
    #expect(i.command == .idle)
}

@Test func compositionVectorIsFixedWidth() {
    // Every encoded vector must be exactly BATCH_CTRL_WIDTH so the ring
    // all_gather template matches on every rank regardless of composition.
    let a = ClusterBatchComposition.idle.encodeVector()
    let b = ClusterBatchComposition(
        command: .step, bNext: 3, keepIndices: [0, 1],
        admit: [ClusterAdmitRow(promptTokens: Array(0..<100), leftPadding: 0, maxTokens: 16)]
    ).encodeVector()
    #expect(a.count == BATCH_CTRL_WIDTH)
    #expect(b.count == BATCH_CTRL_WIDTH)
}

@Test func compositionRaggedAdmitPreservesOrderAndPadding() {
    // Ragged admit: different prompt lengths + left-paddings must decode back
    // exactly and in order (row order is load-bearing for cache alignment).
    let admit = [
        ClusterAdmitRow(promptTokens: [7, 7], leftPadding: 3, maxTokens: 10),
        ClusterAdmitRow(promptTokens: [8, 8, 8, 8], leftPadding: 1, maxTokens: 20),
        ClusterAdmitRow(promptTokens: [9], leftPadding: 0, maxTokens: 30),
    ]
    let comp = ClusterBatchComposition(command: .step, bNext: 3, keepIndices: [], admit: admit)
    let decoded = ClusterBatchComposition.decode(comp.encodeVector())
    #expect(decoded.admit.count == 3)
    for i in 0..<3 {
        #expect(decoded.admit[i].promptTokens == admit[i].promptTokens)
        #expect(decoded.admit[i].leftPadding == admit[i].leftPadding)
        #expect(decoded.admit[i].maxTokens == admit[i].maxTokens)
    }
}
