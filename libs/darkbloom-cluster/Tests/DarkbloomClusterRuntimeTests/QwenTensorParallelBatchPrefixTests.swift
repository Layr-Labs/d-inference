import Foundation
import MLX
import Testing
@testable import DarkbloomClusterRuntime

@Suite(.serialized)
struct QwenTensorParallelBatchPrefixTests {
    @Test func originalGridAndBilateralVotesNeverSplitFinalChunk() throws {
        for chunk in [1, 5, 128, 512] {
            for count in [1, 2, 5, 511, 512, 513, 4096, 8193] {
                let c = QwenTensorParallelBatchPrefixCache.candidates(promptCount: count,
                    chunkSize: chunk, maximumTokens: 4096)
                #expect(c.count <= 32 && c.allSatisfy { $0 > 0 && $0 < count && $0 <= 4096 && $0 % chunk == 0 })
                #expect(try QwenTensorParallelBatchPrefixCache.agreed(candidates: c, votes: c.map { _ in 1 }) == 0)
                #expect(try QwenTensorParallelBatchPrefixCache.agreed(candidates: c, votes: c.map { _ in 2 }) == c.last ?? 0)
            }
        }
        for votes: [Float] in [[.nan], [.infinity], [-1], [3], [0.5], []] {
            #expect(throws: (any Error).self) { try QwenTensorParallelBatchPrefixCache.agreed(candidates: [512], votes: votes) }
        }
    }

    @Test func immutableIdentityAndAllocatorChargedLRURemainBounded() throws {
        try Device.withDefaultDevice(.cpu) {
            let cache = QwenTensorParallelBatchPrefixCache(enabled: true, budgetBytes: 32)
            let tokens = [1, 2, 3, 4, 5, 6]
            func keys(_ scope: String, _ input: [Int] = tokens) -> [Int: String] {
                QwenTensorParallelBatchPrefixCache.keys(scope: scope, tokens: input, frontiers: [2, 4])
            }
            let k = keys("load|media=A"), other = keys("load|media=B")
            #expect(k != other)
            #expect(k[2] == keys("load|media=A", [1, 2, 9, 4, 5, 6])[2])
            #expect(k[4] != keys("load|media=A", [1, 2, 9, 4, 5, 6])[4])
            func state(_ frontier: Int, _ bytes: Int) -> QwenTensorParallelBatchPrefixState {
                .init(committedTokens: frontier, attention: [:], recurrent: [:], allocatedBytes: bytes)
            }
            cache.insert(key: k[2]!, state: state(2, 16)); cache.insert(key: k[4]!, state: state(4, 16))
            #expect(cache.bytesInUse == 32)
            _ = try cache.restore(key: k[2]!, frontier: 2)
            cache.insert(key: other[2]!, state: state(2, 16))
            #expect(cache.held(keys: k, candidates: [2, 4]) == [1, 0])
            #expect(cache.bytesInUse == 32)
            cache.insert(key: "too-large", state: state(4, 33))
            #expect(cache.bytesInUse == 32)
            #expect(throws: (any Error).self) { try cache.restore(key: k[2]!, frontier: 4) }
            cache.sweep(); #expect(cache.bytesInUse == 0 && cache.held(keys: k, candidates: [2, 4]) == [0, 0])
            let off = QwenTensorParallelBatchPrefixCache(enabled: false, budgetBytes: 32)
            off.insert(key: k[2]!, state: state(2, 16)); #expect(off.bytesInUse == 0)
        }
    }

    @Test func fullGeometrySnapshotAndResidentBanksAreIndependentlyRounded() throws {
        let g = try QwenLongPrefillBudgetGeometry(layers: 4, fullAttentionInterval: 4, hiddenSize: 256,
            queryHeads: 4, kvHeads: 2, headDimension: 64, linearKeyHeads: 2, linearValueHeads: 4,
            linearKeyDimension: 64, linearValueDimension: 64, convolutionKernel: 4)
        func bound(_ n: Int) -> Int { (n + 16383) / 16384 * 16384 }
        for n in [1, 17, 4096, 65536] {
            let actual = try QwenTensorParallelBatchPrefixBudget.derive(geometry: g,
                maximumTokens: n, allocationBound: bound)
            let tokens = min(n, 4096)
            let b = try QwenLongPrefillTensorBudget.estimate(geometry: g, maximumTokens: tokens, chunkSize: 1)
            let expected = 3 * (bound(b.convolutionBytesPerLayer) + bound(b.ssmBytesPerLayer))
                + 2 * bound(tokens * 2 * 64 * 2)
            #expect(actual.captureBytes == expected && actual.residentBytes == 2 * expected)
            #expect(actual.maximumTokens == tokens)
        }
        #expect(throws: (any Error).self) {
            try QwenTensorParallelBatchPrefixBudget.derive(geometry: g, maximumTokens: 4096, allocationBound: { $0 - 1 })
        }
        #expect(throws: (any Error).self) {
            try QwenTensorParallelBatchPrefixBudget.derive(geometry: g, maximumTokens: 4096, allocationBound: { _ in Int.max })
        }
    }
}
