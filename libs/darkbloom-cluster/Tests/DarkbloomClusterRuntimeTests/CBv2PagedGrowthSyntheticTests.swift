import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

// Paged rows whose pages grow with the request (`CBv2OwnedRequestState.growReservation`
// over `PagedKVBackend.extendReservation`), on the synthetic Qwen 3.5 of
// `CBv2PagedBatchSyntheticTests`: a request opened for its first tokens and
// grown between steps computes every logits row the whole-length reservation
// computes, bit for bit, alone or batched with another lane; the pool charges
// only what is reserved and gets all of it back; a write past the reservation
// is refused before its forward; and a request past 65,536 tokens grows to its
// length, up to the 27B's longest (262,144).
//
// A contract test on a synthetic model, not a model or hardware result.
@Suite("Paged stage KV grows on demand on a synthetic Qwen 3.5 (no artifact)", .serialized)
struct CBv2PagedGrowthSyntheticTests {
    typealias Synthetic = CBv2PagedBatchSyntheticTests

    private static func reservedBytes(_ host: CBv2StageKVHost) -> Int {
        (host.backend as! PagedKVBackend).pool.bytesReserved
    }

    private static func geometry(_ model: Qwen35TextModel, host: CBv2StageKVHost, maximumTokens: Int,
                                 positions: Int = 4096) throws -> CBv2RequestGeometry {
        try CBv2RequestGeometry(model: model, family: .qwen35,
            feedForwardKind: QwenRoutedExpertStageModel.feedForwardKind(model), layerCount: 8,
            vocabularySize: Synthetic.vocabulary, configurationData: Synthetic.configuration(maximumPositions: positions),
            maximumTokens: maximumTokens, host: host)
    }

    private static func prompt(_ count: Int, salt: Int = 0) -> [Int] {
        (0..<count).map { ($0 * 37 + salt * 11 + 5) % Synthetic.vocabulary }
    }

    /// Grows by `granule` tokens past what the next forward writes plus
    /// `margin`, before the forward; counts the growths.
    private final class Growth {
        let granule: Int, margin: Int
        private(set) var count = 0
        init(granule: Int, margin: Int) { self.granule = granule; self.margin = margin }
        func before(_ state: CBv2OwnedRequestState, writing tokens: Int) throws {
            let needed = state.committedTokens + tokens + margin
            guard needed > state.reservedTokens, state.reservedTokens < state.maximumTokens else { return }
            try state.growReservation(toTokens: needed + granule)
            count += 1
        }
    }

    /// Prefill in `chunk`s, then decode greedily to `outputs` tokens: every
    /// logits row, the prefill's last first.
    private static func run(_ model: Qwen35TextModel, _ state: CBv2OwnedRequestState, prompt: [Int], outputs: Int,
                            chunk: Int, growth: Growth?) throws -> [[Float]] {
        var offset = 0, last: MLXArray?
        while offset < prompt.count {
            let part = Array(prompt[offset..<min(prompt.count, offset + chunk)])
            try growth?.before(state, writing: part.count)
            last = try state.run(tokenCount: part.count, check: {}, forward: { caches, evaluation in
                Synthetic.logits(model, [part], caches: caches, evaluations: [evaluation])
            }, validateOutput: { _ in })
            offset += part.count
        }
        var row = last!
        var rows = [row.asType(.float32).asArray(Float.self)]
        while rows.count < outputs {
            let token = Synthetic.argmax(row)
            try growth?.before(state, writing: 1)
            row = try state.run(tokenCount: 1, check: {}, forward: { caches, evaluation in
                Synthetic.logits(model, [[token]], caches: caches, evaluations: [evaluation])
            }, validateOutput: { _ in })
            rows.append(row.asType(.float32).asArray(Float.self))
        }
        return rows
    }

    /// One host lane takes the prompt-chunk mirror, two take the gather.
    @Test(arguments: [1, 2])
    func aGrowingReservationComputesEveryRowTheWholeReservationComputes(lanes: Int) throws {
        let model = try Synthetic.model()
        let host = try CBv2StageKVHost(model: model, kind: .paged, lanes: lanes, maximumTokensPerRequest: 512,
            maximumChunkTokens: Synthetic.chunk)
        let prompt = Self.prompt(45), outputs = 150, maximum = 45 + 150
        let whole = try CBv2OwnedRequestState(geometry: Self.geometry(model, host: host, maximumTokens: maximum),
            promptCount: prompt.count, outputCount: outputs)
        let wholeBytes = Self.reservedBytes(host)
        #expect(whole.reservedTokens == maximum && wholeBytes > 0)
        let expected = try Self.run(model, whole, prompt: prompt, outputs: outputs, chunk: Synthetic.chunk, growth: nil)
        try whole.retire()
        #expect(host.isDrained && Self.reservedBytes(host) == 0)

        // Opened for its prompt and three tokens; grown 13 tokens at a time
        // (never on a page boundary of 16) whenever the next forward and a
        // margin of 4 would pass it.
        let growing = try CBv2OwnedRequestState(geometry: Self.geometry(model, host: host, maximumTokens: maximum),
            promptCount: prompt.count, outputCount: outputs, reservedTokens: prompt.count + 3)
        #expect(growing.reservedTokens == 48 && growing.maximumTokens == maximum)
        #expect(Self.reservedBytes(host) < wholeBytes)
        let growth = Growth(granule: 13, margin: 4)
        let actual = try Self.run(model, growing, prompt: prompt, outputs: outputs, chunk: Synthetic.chunk, growth: growth)
        #expect(growth.count > 5)
        #expect(actual.count == expected.count)
        for (index, (a, b)) in zip(actual, expected).enumerated() {
            #expect(a == b, "lanes=\(lanes) row \(index) differs from the whole reservation's")
        }
        // Grown to its length, it holds what the whole reservation held.
        #expect(growing.reservedTokens == maximum && Self.reservedBytes(host) == wholeBytes)
        try growing.retire()
        #expect(host.isDrained && Self.reservedBytes(host) == 0)
    }

    /// Two lanes decode together, each growing at its own steps: every
    /// batched row equals its request's own whole-reservation row.
    @Test func batchedLanesGrowIndependentlyAndKeepEveryRow() throws {
        let model = try Synthetic.model()
        let host = try CBv2StageKVHost(model: model, kind: .paged, lanes: 2, maximumTokensPerRequest: 512,
            maximumChunkTokens: Synthetic.chunk)
        let prompts = [Self.prompt(21, salt: 1), Self.prompt(38, salt: 2)], outputs = 90
        let alone = try prompts.map { prompt -> [[Float]] in
            let state = try CBv2OwnedRequestState(geometry: Self.geometry(model, host: host, maximumTokens: prompt.count + outputs),
                promptCount: prompt.count, outputCount: outputs)
            defer { try? state.retire() }
            return try Self.run(model, state, prompt: prompt, outputs: outputs, chunk: Synthetic.chunk, growth: nil)
        }
        #expect(host.isDrained)
        let growths = [Growth(granule: 5, margin: 1), Growth(granule: 17, margin: 3)]
        var states: [CBv2OwnedRequestState] = []
        var tokens: [[Int]] = [[], []]
        for (lane, prompt) in prompts.enumerated() {
            let state = try CBv2OwnedRequestState(geometry: Self.geometry(model, host: host, maximumTokens: prompt.count + outputs),
                promptCount: prompt.count, outputCount: outputs, reservedTokens: prompt.count)
            var offset = 0, last: MLXArray?
            while offset < prompt.count {
                let part = Array(prompt[offset..<min(prompt.count, offset + Synthetic.chunk)])
                last = try state.run(tokenCount: part.count, check: {}, forward: { caches, evaluation in
                    Synthetic.logits(model, [part], caches: caches, evaluations: [evaluation])
                }, validateOutput: { _ in })
                offset += part.count
            }
            #expect(last!.asType(.float32).asArray(Float.self) == alone[lane][0])
            tokens[lane] = [Synthetic.argmax(last!)]
            states.append(state)
        }
        for step in 1..<outputs {
            for lane in 0..<2 { try growths[lane].before(states[lane], writing: 1) }
            let rows = try CBv2OwnedRequestState.runBatch(states, tokenCount: 1, check: {},
                forward: { caches, evaluations in
                    Synthetic.logits(model, tokens.map { [$0.last!] }, caches: caches, evaluations: evaluations)
                }, validateOutput: { _ in })
            for lane in 0..<2 {
                #expect(rows[lane].asType(.float32).asArray(Float.self) == alone[lane][step], "lane \(lane) step \(step)")
                tokens[lane].append(Synthetic.argmax(rows[lane]))
            }
        }
        #expect(growths.allSatisfy { $0.count > 3 })
        for state in states { try state.retire() }
        #expect(host.isDrained && Self.reservedBytes(host) == 0)
    }

    @Test func aWriteBeyondTheReservationIsRefusedBeforeItsForward() throws {
        let model = try Synthetic.model()
        let host = try CBv2StageKVHost(model: model, kind: .paged, lanes: 1, maximumTokensPerRequest: 64,
            maximumChunkTokens: Synthetic.chunk)
        let prompt = Self.prompt(16)
        // Below the prompt, or on storage that cannot grow, is refused at open.
        #expect(throws: (any Error).self) {
            _ = try CBv2OwnedRequestState(geometry: Self.geometry(model, host: host, maximumTokens: 24),
                promptCount: 16, outputCount: 8, reservedTokens: 15)
        }
        let contiguous = try CBv2StageKVHost(model: model, kind: .contiguous, lanes: 1, maximumTokensPerRequest: 64,
            maximumChunkTokens: Synthetic.chunk)
        #expect(throws: (any Error).self) {
            _ = try CBv2OwnedRequestState(geometry: Self.geometry(model, host: contiguous, maximumTokens: 24),
                promptCount: 16, outputCount: 8, reservedTokens: 20)
        }
        #expect(host.isDrained && contiguous.isDrained)
        let state = try CBv2OwnedRequestState(geometry: Self.geometry(model, host: host, maximumTokens: 24),
            promptCount: 16, outputCount: 8, reservedTokens: 16)
        let rows = try Self.run(model, state, prompt: prompt, outputs: 1, chunk: Synthetic.chunk, growth: nil)
        #expect(rows.count == 1 && state.committedTokens == 16)
        // A smaller target, or one past the request's length, changes nothing past it.
        try state.growReservation(toTokens: 8)
        #expect(state.reservedTokens == 16)
        var forwarded = false
        #expect(throws: (any Error).self) {
            _ = try state.run(tokenCount: 1, check: {}, forward: { caches, evaluation in
                forwarded = true
                return Synthetic.logits(model, [[1]], caches: caches, evaluations: [evaluation])
            }, validateOutput: { _ in })
        }
        #expect(!forwarded && state.isFailed && state.committedTokens == 16)
        try state.retire(failed: true)
        #expect(host.isDrained && Self.reservedBytes(host) == 0)
        let clamped = try CBv2OwnedRequestState(geometry: Self.geometry(model, host: host, maximumTokens: 24),
            promptCount: 16, outputCount: 8, reservedTokens: 16)
        try clamped.growReservation(toTokens: 1_000)
        #expect(clamped.reservedTokens == 24)
        try clamped.retire()
        #expect(host.isDrained)
    }

    /// Past the standard 65,536-token context: a prompt that ends six tokens
    /// before it, grown a few tokens at a time across it, computes every row
    /// the whole reservation computes.
    @Test func aRequestGrowsAcrossTheStandardContextWithoutChangingARow() throws {
        let model = try Synthetic.model()
        let host = try CBv2StageKVHost(model: model, kind: .paged, lanes: 1, maximumTokensPerRequest: 65_536 + 64,
            maximumChunkTokens: 512)
        let prompt = Self.prompt(65_530, salt: 3), outputs = 40, maximum = prompt.count + outputs
        func open(reserved: Int?) throws -> CBv2OwnedRequestState {
            try CBv2OwnedRequestState(geometry: Self.geometry(model, host: host, maximumTokens: maximum, positions: 262_144),
                promptCount: prompt.count, outputCount: outputs, reservedTokens: reserved)
        }
        let whole = try open(reserved: nil)
        let wholeBytes = Self.reservedBytes(host)
        let expected = try Self.run(model, whole, prompt: prompt, outputs: outputs, chunk: 512, growth: nil)
        try whole.retire()
        #expect(host.isDrained)
        let growing = try open(reserved: prompt.count)
        #expect(Self.reservedBytes(host) < wholeBytes)
        let growth = Growth(granule: 7, margin: 2)
        let actual = try Self.run(model, growing, prompt: prompt, outputs: outputs, chunk: 512, growth: growth)
        #expect(growth.count >= 4 && growing.reservedTokens == maximum && maximum > 65_536)
        for (index, (a, b)) in zip(actual, expected).enumerated() {
            #expect(a == b, "row \(index) differs from the whole reservation's")
        }
        #expect(Self.reservedBytes(host) == wholeBytes)
        try growing.retire()
        #expect(host.isDrained && Self.reservedBytes(host) == 0)
    }

    /// The 27B's longest request (229,376 prompt and 32,768 output tokens)
    /// opened for its prompt and one 1,024-token granule, grown granule by
    /// granule (`QwenTensorParallelBatchSession.pageGrowthTarget`) to 262,144
    /// tokens: the pool charges each reservation exactly and, grown to its
    /// length, what the whole reservation charged. Bookkeeping only: no forward.
    @Test func theLongestNativeRequestGrowsGranuleByGranuleToItsLength() throws {
        let model = try Synthetic.model()
        let host = try CBv2StageKVHost(model: model, kind: .paged, lanes: 1, maximumTokensPerRequest: 262_144,
            maximumChunkTokens: 512)
        let prompt = 229_376, outputs = 32_768
        let geometry = try Self.geometry(model, host: host, maximumTokens: 262_144, positions: 262_144)
        let whole = try CBv2OwnedRequestState(geometry: geometry, promptCount: prompt, outputCount: outputs)
        let wholeBytes = Self.reservedBytes(host)
        try whole.retire()
        // Two full-attention layers, each page 16 tokens of 2 heads x 64 x BF16, keys and values.
        let pageBytes = 16 * 2 * 64 * 2 * 2 * 2
        #expect(wholeBytes == 262_144 / 16 * pageBytes)
        let request = try QwenLayerStageGenerationRequest(profile: QwenLayerStageGenerationProfile(
                identifier: "qwen-native-growth-synthetic", vocabularySize: Synthetic.vocabulary, hiddenSize: 128,
                activationDType: "bfloat16", maximumPromptTokens: 262_143, maximumChunkTokens: 512,
                maximumOutputTokens: 32_768, maximumContextTokens: 262_144),
            requestID: UUID(), promptTokenIDs: Array(repeating: 7, count: prompt), chunkSize: 512,
            outputCount: outputs, stopTokenIDs: [])
        let state = try CBv2OwnedRequestState(geometry: geometry, promptCount: prompt, outputCount: outputs,
            reservedTokens: QwenTensorParallelBatchSession.initialReservedTokens(request))
        #expect(state.reservedTokens == prompt + QwenTensorParallelBatchSession.pageGrowthTokens)
        #expect(Self.reservedBytes(host) == (state.reservedTokens + 15) / 16 * pageBytes)
        // What the decode loop asks before each step: every token it writes is reserved.
        var growths = 0
        for committed in prompt..<(request.finalCommittedTokens) {
            if let target = QwenTensorParallelBatchSession.pageGrowthTarget(reserved: state.reservedTokens,
                needed: committed + 1, limit: request.maximumTokens) {
                try state.growReservation(toTokens: target)
                growths += 1
                #expect(state.reservedTokens == target)
                #expect(Self.reservedBytes(host) == (target + 15) / 16 * pageBytes)
            }
            #expect(committed + 1 <= state.reservedTokens)
        }
        #expect(state.reservedTokens == 262_144 && Self.reservedBytes(host) == wholeBytes)
        #expect(growths == (262_144 - (prompt + 1024) + 1023) / 1024)
        try state.retire()
        #expect(host.isDrained && Self.reservedBytes(host) == 0)
    }
}
