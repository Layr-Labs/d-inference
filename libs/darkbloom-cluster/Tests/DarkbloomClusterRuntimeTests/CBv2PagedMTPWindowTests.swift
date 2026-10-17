import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

// A speculative (MTP verify) window on a stage KV host, on the synthetic
// Qwen 3.5 of `CBv2PagedBatchSyntheticTests`. On a paged host every layer
// cache must attend the window one query column at a time (the one-token
// decode kernel per column), as the single-Mac engine's verification round
// does; without that scope a paged cache serves the window as a prompt chunk
// and re-gathers the request's whole history per layer per round (9B at 30K
// on the pair: MTP decode 25.7 vs 133 tok/s contiguous). Contiguous storage
// keeps the window it always had. The window's tokens must equal the same
// tokens decoded one at a time, on both backends.
//
// A contract test on a synthetic model, not a model or hardware result.

@Suite("MTP verify windows on the stage KV host (synthetic Qwen 3.5, no artifact)", .serialized)
struct CBv2PagedMTPWindowTests {
    typealias Synthetic = CBv2PagedBatchSyntheticTests
    static let prompt = [3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5, 8, 9, 7, 9, 3, 2, 3, 8, 4]

    /// Prefill: the committed frontier and the greedy next token every case
    /// starts from.
    static func start(_ model: Qwen35TextModel, host: CBv2StageKVHost) throws -> (CBv2OwnedRequestState, Int) {
        let state = try CBv2OwnedRequestState(geometry: Synthetic.geometry(model, host: host),
            promptCount: prompt.count, outputCount: 16)
        let row = try Synthetic.prefill(model, state, prompt)
        return (state, Synthetic.argmax(row))
    }

    /// Greedy tokens of a `count`-wide window fed `tokens`, everything kept;
    /// records whether every layer cache was serialising while the window's
    /// graph was built, and whether it still is afterwards.
    static func window(_ model: Qwen35TextModel, _ state: CBv2OwnedRequestState, host: CBv2StageKVHost,
                       tokens: [Int]) throws -> (tokens: [Int], serialisedDuringBuild: Bool, serialisedAfter: Bool) {
        var during = false
        let input = MLXArray(tokens.map(Int32.init)).reshaped([1, tokens.count])
        let built = try state.beginWindow(tokenCount: tokens.count) { caches, evaluation in
            during = host.bank.isSerializingMTPRectangularVerification
            return [model.cbv2ForwardWithHiddenCaptured(input, caches: caches.map { $0 as! any KVCache },
                recurrentState: [evaluation], positionIds: nil).logits]
        }
        let after = host.bank.isSerializingMTPRectangularVerification
        eval(built.outputs + built.roots)
        try state.confirmWindow(check: {})
        let settled = try state.settleWindow(keeping: tokens.count)
        eval(settled)
        try state.confirmSettled(check: {})
        let logits = built.outputs[0]
        let picked = (0..<tokens.count).map { Synthetic.argmax(logits[0, $0, 0...]) }
        return (picked, during, after)
    }

    /// The same tokens one at a time.
    static func sequential(_ model: Qwen35TextModel, _ state: CBv2OwnedRequestState, tokens: [Int]) throws -> [Int] {
        try tokens.map { token in
            Synthetic.argmax(try state.run(tokenCount: 1, check: {}, forward: { caches, evaluation in
                Synthetic.logits(model, [[token]], caches: caches, evaluations: [evaluation])
            }, validateOutput: { _ in }))
        }
    }

    @Test(arguments: [ClusterStageKVBackendKind.paged, .contiguous])
    func windowSerialisesOnPagedOnlyAndMatchesOneTokenDecode(kind: ClusterStageKVBackendKind) throws {
        let model = try Synthetic.model()
        let host = try CBv2StageKVHost(model: model, kind: kind, lanes: 1, maximumTokensPerRequest: 64,
            maximumChunkTokens: Synthetic.chunk)
        // Drafts: the next token followed by three arbitrary ids.
        let (windowState, next) = try Self.start(model, host: host)
        let drafts = [next, 17, 42, 7]
        let windowed = try Self.window(model, windowState, host: host, tokens: drafts)
        #expect(windowed.serialisedDuringBuild == (kind == .paged),
            "\(kind): a paged host must build the verify window column-serial, a contiguous one unchanged")
        #expect(!windowed.serialisedAfter, "\(kind): the serialisation scope must close with the window")
        try windowState.retire()

        let (plainState, plainNext) = try Self.start(model, host: host)
        #expect(plainNext == next)
        let plain = try Self.sequential(model, plainState, tokens: drafts)
        #expect(windowed.tokens == plain, "\(kind): window tokens differ from one-token decode")
        try plainState.retire()
        #expect(host.isDrained)
    }

    @Test func pagedAndContiguousWindowsAgree() throws {
        let model = try Synthetic.model()
        var results: [[Int]] = []
        for kind in [ClusterStageKVBackendKind.paged, .contiguous] {
            let host = try CBv2StageKVHost(model: model, kind: kind, lanes: 1, maximumTokensPerRequest: 64,
                maximumChunkTokens: Synthetic.chunk)
            let (state, next) = try Self.start(model, host: host)
            var tokens = [next], committed: [Int] = []
            // Three rounds of a four-wide window, each fed its own greedy picks.
            for _ in 0..<3 {
                let drafts = [tokens.last!, 11, 23, 5]
                let picked = try Self.window(model, state, host: host, tokens: drafts).tokens
                committed += picked; tokens.append(picked.last!)
            }
            try state.retire()
            #expect(host.isDrained)
            results.append(committed)
        }
        #expect(results[0] == results[1], "paged and contiguous verify windows pick different tokens")
    }
}

// Interim default (2026-10-12): a stage that decodes one request at a time with
// a speculative head stores its KV contiguously unless the launch names a
// backend; batch lanes and stages without a head keep paged. Model-free.
@Suite("Stage KV backend default follows what the stage serves")
struct ClusterStageKVBackendDefaultTests {
    @Test func oneRequestMTPStagesDefaultToContiguousEverythingElseToPaged() throws {
        #expect(try ClusterStageKVBackendKind.resolved(environment: [:], speculative: true, batchLanes: 1) == .contiguous)
        #expect(try ClusterStageKVBackendKind.resolved(environment: [:], speculative: false, batchLanes: 1) == .paged)
        for lanes in 2...8 {
            #expect(try ClusterStageKVBackendKind.resolved(environment: [:], speculative: true, batchLanes: lanes) == .paged)
            #expect(try ClusterStageKVBackendKind.resolved(environment: [:], speculative: false, batchLanes: lanes) == .paged)
        }
        // The plain default the other tools read is unchanged.
        #expect(try ClusterStageKVBackendKind.fromEnvironment([:]) == .paged)
    }

    @Test func aNamedBackendAlwaysWinsAndAnUnknownOneStopsTheLoad() throws {
        let name = ClusterStageKVBackendKind.environmentName
        for speculative in [true, false] {
            for lanes in [1, 4] {
                #expect(try ClusterStageKVBackendKind.resolved(environment: [name: "paged"], speculative: speculative,
                    batchLanes: lanes) == .paged)
                #expect(try ClusterStageKVBackendKind.resolved(environment: [name: " Contiguous "], speculative: speculative,
                    batchLanes: lanes) == .contiguous)
                #expect(throws: (any Error).self) {
                    _ = try ClusterStageKVBackendKind.resolved(environment: [name: "ring"], speculative: speculative,
                        batchLanes: lanes)
                }
            }
        }
        #expect(try ClusterStageKVBackendKind.resolved(environment: [name: "  "], speculative: true, batchLanes: 1) == .contiguous)
    }
}
