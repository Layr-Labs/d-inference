import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

// The three paged-engine gaps that kept one-request MTP stages on contiguous KV
// (PERF-BACKLOG items 23-25), on the synthetic Qwen 3.5 of
// `CBv2PagedBatchSyntheticTests` (two full-attention layers, GQA 2):
//  23. a prompt chunk attends the row's history without gathering it out of
//      the pages again (the transient contiguous prefill mirror), and the
//      mirror is gone once the row decodes;
//  24. a verify window reads the context once (one multi-query dispatch per
//      full-attention layer per window, not one decode row per column);
//  25. the per-step frontier check reads the host mirror of the caches'
//      device offsets, which must equal the device array after prompt
//      chunks, windows and rollbacks.
// Tokens must equal contiguous storage throughout.
//
// Failing first: `DARKBLOOM_PAGED_PREFILL_MIRROR=0` and
// `DARKBLOOM_PAGED_MTP_MULTI_QUERY=0` restore the previous paths, and these
// tests then fail on the gather / dispatch expectations (only those).
//
// A contract test on a synthetic model, not a model or hardware result.

@Suite("Paged engine gaps 23-25 on the stage KV host (synthetic Qwen 3.5, no artifact)", .serialized)
struct CBv2PagedEngineGapTests {
    typealias Synthetic = CBv2PagedBatchSyntheticTests
    typealias Window = CBv2PagedMTPWindowTests
    // Three prompt chunks of `Synthetic.chunk` (8) tokens and a partial one.
    static let prompt = [3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5, 8, 9, 7, 9, 3, 2, 3, 8, 4, 6, 2, 6, 4, 3, 3]

    static func pagedCaches(_ host: CBv2StageKVHost) -> [PagedLayerCache] {
        host.caches.compactMap { $0 as? PagedLayerCache }
    }

    static func host(_ model: Qwen35TextModel, _ kind: ClusterStageKVBackendKind, lanes: Int = 1) throws
        -> CBv2StageKVHost {
        try CBv2StageKVHost(model: model, kind: kind, lanes: lanes, maximumTokensPerRequest: 64,
            maximumChunkTokens: Synthetic.chunk)
    }

    /// Prompt, then a greedy one-token step; the tokens and, on paged, what
    /// the prompt cost in history gathers.
    static func promptAndStep(_ model: Qwen35TextModel, _ kind: ClusterStageKVBackendKind, lanes: Int = 1) throws
        -> (tokens: [Int], gathers: Int, mirrorChunks: Int, mirrorBytesAfterPrompt: Int, mirrorBytesAfterStep: Int) {
        let host = try Self.host(model, kind, lanes: lanes)
        let state = try CBv2OwnedRequestState(geometry: Synthetic.geometry(model, host: host),
            promptCount: prompt.count, outputCount: 16)
        let next = Synthetic.argmax(try Synthetic.prefill(model, state, prompt))
        let caches = pagedCaches(host)
        let gathers = caches.reduce(0) { $0 + $1.prefillHistoryGathers }
        let chunks = caches.reduce(0) { $0 + $1.prefillMirrorChunks }
        let bytesAfterPrompt = caches.reduce(0) { $0 + $1.prefillMirrorBytes }
        let decoded = try Window.sequential(model, state, tokens: [next, 17, 42])
        let bytesAfterStep = caches.reduce(0) { $0 + $1.prefillMirrorBytes }
        try state.retire()
        #expect(host.isDrained)
        return ([next] + decoded, gathers, chunks, bytesAfterPrompt, bytesAfterStep)
    }

    @Test func pagedPromptChunksReadNoHistoryGatherAndMatchContiguous() throws {
        let model = try Synthetic.model()
        let paged = try Self.promptAndStep(model, .paged)
        let contiguous = try Self.promptAndStep(model, .contiguous)
        let chunks = (Self.prompt.count + Synthetic.chunk - 1) / Synthetic.chunk
        // Two full-attention layers, each serving every chunk from its mirror.
        #expect(paged.gathers == 0, "a paged prompt chunk re-gathered the row's history from its pages")
        #expect(paged.mirrorChunks == 2 * chunks)
        #expect(paged.mirrorBytesAfterPrompt > 0)
        #expect(paged.mirrorBytesAfterStep == 0, "the prefill mirror outlived the prompt")
        #expect(paged.tokens == contiguous.tokens, "paged prompt tokens differ from contiguous")
    }

    /// The mirror is transient memory the pool does not charge, so only the
    /// one-request host (whose per-request budget bounds it) opts in; a
    /// batch-lane host keeps the gather, with the same tokens.
    @Test func batchLaneHostKeepsTheGatherAndMatchesContiguous() throws {
        let model = try Synthetic.model()
        let paged = try Self.promptAndStep(model, .paged, lanes: 2)
        let contiguous = try Self.promptAndStep(model, .contiguous, lanes: 2)
        #expect(paged.mirrorChunks == 0, "a batch-lane host used the uncharged prefill mirror")
        #expect(paged.gathers > 0)
        #expect(paged.tokens == contiguous.tokens, "batch-lane paged prompt tokens differ from contiguous")
    }

    @Test func pagedVerifyWindowReadsTheContextOncePerWindow() throws {
        let model = try Synthetic.model()
        var results: [[Int]] = []
        for kind in [ClusterStageKVBackendKind.paged, .contiguous] {
            let host = try Self.host(model, kind)
            let state = try CBv2OwnedRequestState(geometry: Synthetic.geometry(model, host: host),
                promptCount: Self.prompt.count, outputCount: 16)
            var last = Synthetic.argmax(try Synthetic.prefill(model, state, Self.prompt))
            var committed: [Int] = []
            for _ in 0..<3 {
                let picked = try Window.window(model, state, host: host, tokens: [last, 11, 23, 5]).tokens
                committed += picked; last = picked.last!
            }
            if kind == .paged {
                let calls = Self.pagedCaches(host).map(\.mtpMultiQueryCalls)
                #expect(calls == [3, 3], "each window must be one multi-query pass per full-attention layer: \(calls)")
            }
            try state.retire()
            #expect(host.isDrained)
            results.append(committed)
        }
        #expect(results[0] == results[1], "paged multi-query windows pick different tokens than contiguous")
    }

    @Test func hostFrontierMirrorsTheDeviceOffsetsThroughRollbacks() throws {
        let model = try Synthetic.model()
        let host = try Self.host(model, .paged)
        let state = try CBv2OwnedRequestState(geometry: Synthetic.geometry(model, host: host),
            promptCount: Self.prompt.count, outputCount: 16)
        let next = Synthetic.argmax(try Synthetic.prefill(model, state, Self.prompt))
        func agree(_ count: Int) {
            for cache in Self.pagedCaches(host) {
                #expect(cache.hostPositionOffsets == [Int32(count)])
                #expect(cache.positionOffsets.asArray(Int32.self) == cache.hostPositionOffsets)
            }
        }
        agree(Self.prompt.count)
        // A window that keeps two of four tokens rolls every row back by two.
        let input = MLXArray([next, 11, 23, 5].map(Int32.init)).reshaped([1, 4])
        let built = try state.beginWindow(tokenCount: 4) { caches, evaluation in
            [model.cbv2ForwardWithHiddenCaptured(input, caches: caches.map { $0 as! any KVCache },
                recurrentState: [evaluation], positionIds: nil).logits]
        }
        eval(built.outputs + built.roots)
        try state.confirmWindow(check: {})
        eval(try state.settleWindow(keeping: 2))
        try state.confirmSettled(check: {})
        agree(Self.prompt.count + 2)
        _ = try Window.sequential(model, state, tokens: [7])
        agree(Self.prompt.count + 3)
        // Full validation (device read) still passes on the same state.
        try state.validateState(after: Self.prompt.count + 3, storageViews: true)
        try state.retire()
        #expect(host.isDrained)
    }
}
