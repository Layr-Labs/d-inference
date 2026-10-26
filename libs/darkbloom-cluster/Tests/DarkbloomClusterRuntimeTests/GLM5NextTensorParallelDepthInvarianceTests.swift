import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

/// Opt-in (`GLM53_DEPTH_INVARIANCE=1`, GPU, the synthetic serving-policy stage
/// and NextN layer of `GLM5NextTensorParallelSpeculationRowsTests`, whole and
/// as rank 0 of a two-rank split, paged histories): with the width-invariant
/// switch (`GLM5NextTensorParallelDecodePolicy.widthInvariant`: one-row windows
/// padded, `GLM5NextTextStage.widthInvariantWindows`), a request decodes to the
/// same tokens, the same logits for every token and the same caches whatever
/// the depth of each round (1, 2 or 3), whatever its proposals keep, and
/// whatever other requests decode beside it under the `load` policy: exactly
/// its depth-2 decode alone.
@Suite(.serialized)
struct GLM5NextTensorParallelDepthInvarianceTests {
    typealias Rows = GLM5NextTensorParallelSpeculationRowsTests
    typealias Paged = GLM5NextTensorParallelPagedKVTests
    typealias Speculation = GLM5NextTensorParallelSpeculation
    typealias Policy = GLM5NextTensorParallelDecodePolicy
    static let enabled = ProcessInfo.processInfo.environment["GLM53_DEPTH_INVARIANCE"] == "1"

    /// A request's decode: its tokens (the prefill's first one included),
    /// each later token's logits row and its final cache state, as bytes.
    struct Decoded {
        var tokens: [Int]
        var logits: [Data]
        var states: [Data]
    }

    /// `depth` above 2: the request's speculation is rebuilt at that depth
    /// (`Paged.Request` builds depth 2), its history primed alike.
    static func request(_ stage: GLM5NextTextStage, _ mtp: GLM5NextMTP, pool: GLM5NextDSAPagePool, prompt: [Int],
                        outputs: Int, padded: Bool = true, depth: Int = 2) throws -> Paged.Request {
        let request = try Paged.Request(stage: stage, mtp: mtp, pool: pool, prompt: prompt, outputs: outputs,
            depth: depth)
        request.speculation.padsSingleRowWindows = padded
        request.speculation.recordsKeptLogits = true
        request.tokens = [request.last]
        return request
    }

    static func decoded(_ request: Paged.Request) throws -> Decoded {
        let rows = request.speculation.keptLogits
        try Rows.fence(rows + request.cache.layers.flatMap(\.state))
        let logits = rows.flatMap { kept in (0 ..< kept.dim(1)).map { Rows.bytes(kept[0..., $0, 0...]) } }
        return Decoded(tokens: request.tokens, logits: logits, states: request.cache.layers.flatMap(\.state).map(Rows.bytes))
    }

    /// Proposals for a round after `committed` tokens: `reference`'s next
    /// tokens for the first `keep` positions, then one that differs (so the
    /// round keeps exactly `keep` proposals while the decode follows the
    /// reference).
    static func oracle(_ reference: [Int], committed: Int, keep: Int, vocabulary: Int) -> GLM5NextMTP.ProposalSelection {
        { _, step in
            let index = min(committed + step, reference.count - 1)
            let token = step < keep ? reference[index] : (reference[index] + 1) % vocabulary
            return MLXArray([Int32(token)])
        }
    }

    /// Decodes alone to `outputs` tokens; round `k` verifies `depth(k)`
    /// proposals at most, proposed by `propose(k, committed)` (nil: the NextN argmax).
    static func alone(_ request: Paged.Request, stage: GLM5NextTextStage, outputs: Int, depth: (Int) -> Int,
                      propose: ((Int, Int) -> GLM5NextMTP.ProposalSelection?)? = nil) throws {
        var round = 0
        while request.tokens.count < outputs {
            let window = max(0, min(depth(round), outputs - request.tokens.count - 1))
            let decided = try request.speculation.round(stage: stage, cache: request.cache, last: request.last,
                window: window, stop: 0, propose: propose?(round, request.tokens.count))
            request.tokens += decided.tokens; request.last = decided.tokens.last!
            round += 1
        }
    }

    static func expectEqual(_ a: Decoded, _ b: Decoded, _ label: String) {
        #expect(a.tokens == b.tokens, "\(label) tokens")
        let first = zip(a.logits, b.logits).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        #expect(a.logits.count == b.logits.count && a.logits == b.logits,
            "\(label) logits (first difference at \(first.map(String.init) ?? "-"))")
        #expect(a.states == b.states, "\(label) cache states")
    }

    /// The synthetic stage (whole or rank 0 of two) and its NextN layer, width-invariant.
    static func model(sharded: Bool) throws -> (stage: GLM5NextTextStage, mtp: GLM5NextMTP) {
        let declared = try Rows.configuration()
        let inventory = try GLM5NextWeightInventory.validate(configuration: declared,
            tensors: GLM5NextWeightInventory.expectedTensors(configuration: declared, storage: .nvfp4Hybrid,
                shard: "rows.safetensors"), storage: .nvfp4Hybrid)
        let resolve: (String) throws -> MLXArray = { name in
            guard let entry = inventory.entries[name] else { throw ProbeError("missing \(name)") }
            return Rows.tensor(entry)
        }
        let text = declared.textConfig
        let stage = try GLM5NextTextStage(plan: .init(configuration: text, layers: 0 ..< text.hiddenLayers,
                shard: sharded ? GLM5NextTensorShard(rank: 0, size: 2) : nil),
            inventory: inventory, tensor: resolve, materializeExpertStack: { eval($0) },
            releaseSourceTensors: { _ in }, executionPolicy: .serving, materializeFusedProjections: { eval($0) })
        stage.widthInvariantWindows = true
        let mtp = try GLM5NextMTP(stage: stage, tensor: resolve, materializeExpertStack: { eval($0) },
            releaseSourceTensors: { _ in }, materializeFusedProjections: { eval($0) })
        return (stage, mtp)
    }

    @Test(.enabled(if: enabled), arguments: [false, true])
    func everyDepthAndKeptPatternIsTheDepthTwoDecode(sharded: Bool) throws {
        try Device.withDefaultDevice(.gpu) {
            let (stage, mtp) = try Self.model(sharded: sharded)
            let vocabulary = stage.plan.configuration.vocabularySize
            let pool = try stage.makeDSAPagePool(pageSize: GLM5NextTensorParallelResidentRuntime.dsaPageTokens)
            // Histories that cross a page (63) and the dense-to-sparse DSA switch (2,045 -> 2,061).
            for (lane, length) in [40, 63, 2_045].enumerated() {
                let prompt = (0..<length).map { (($0 + 3) * 7919 + lane * 104_729) % vocabulary }
                let outputs = 23
                let make = { try Self.request(stage, mtp, pool: pool, prompt: prompt, outputs: outputs, depth: 3) }
                let reference = try make()
                try Self.alone(reference, stage: stage, outputs: outputs, depth: { _ in 2 })
                let expected = try Self.decoded(reference)
                let tokens = expected.tokens
                // Depth 1 every round, and depth 3 (four-row windows).
                let one = try make()
                try Self.alone(one, stage: stage, outputs: outputs, depth: { _ in 1 })
                Self.expectEqual(try Self.decoded(one), expected, "history \(length) depth 1")
                let three = try make()
                try Self.alone(three, stage: stage, outputs: outputs, depth: { _ in 3 }, propose: { round, committed in
                    Self.oracle(tokens, committed: committed, keep: [3, 1, 2, 0, 3][round % 5], vocabulary: vocabulary)
                })
                Self.expectEqual(try Self.decoded(three), expected, "history \(length) depth 3")
                // Depth 2, the proposals keeping 2, 0, 1, 2, 1, 0, ...: round boundaries move.
                let kept = try make()
                try Self.alone(kept, stage: stage, outputs: outputs, depth: { _ in 2 }, propose: { round, committed in
                    Self.oracle(tokens, committed: committed, keep: [2, 0, 1, 2, 1, 0][round % 6], vocabulary: vocabulary)
                })
                Self.expectEqual(try Self.decoded(kept), expected, "history \(length) kept pattern")
                // A pseudo-random depth (1 to 3) and kept count every round.
                let random = try make()
                try Self.alone(random, stage: stage, outputs: outputs,
                    depth: { GLM5NextTensorParallelBench.scheduledDepth(round: $0, maximum: 3) },
                    propose: { round, committed in
                        Self.oracle(tokens, committed: committed, keep: (round * 7 + 3) % 4, vocabulary: vocabulary)
                    })
                Self.expectEqual(try Self.decoded(random), expected, "history \(length) random depth")
                #expect(one.speculation.rounds > reference.speculation.rounds || reference.speculation.acceptedTokens == 0)
            }
        }
    }

    /// Requests joining and leaving beside each other under `load` (one
    /// proposal a round from three decoding lanes, two below): each one's
    /// tokens, logits and caches are those of its depth-2 decode alone,
    /// including a last token verified padded beside other lanes.
    @Test(.enabled(if: enabled), arguments: [false, true])
    func loadPolicyLanesAreEachRequestAloneAtDepthTwo(sharded: Bool) throws {
        try Device.withDefaultDevice(.gpu) {
            let (stage, mtp) = try Self.model(sharded: sharded)
            let vocabulary = stage.plan.configuration.vocabularySize
            let pool = try stage.makeDSAPagePool(pageSize: GLM5NextTensorParallelResidentRuntime.dsaPageTokens)
            let policy = Policy(depth: .load, loadLanes: 3)
            // Prompt length, output limit and the step the request starts decoding.
            let specs: [(length: Int, outputs: Int, start: Int)] = [
                (40, 30, 0), (63, 12, 0), (300, 21, 2), (2_061, 17, 3), (9, 9, 9), (2_040, 14, 12),
            ]
            let prompts = specs.enumerated().map { lane, spec in
                (0..<spec.length).map { (($0 + 5) * 7919 + lane * 104_729) % vocabulary }
            }
            let expected = try zip(prompts, specs).map { prompt, spec -> Decoded in
                let request = try Self.request(stage, mtp, pool: pool, prompt: prompt, outputs: spec.outputs)
                try Self.alone(request, stage: stage, outputs: spec.outputs,
                    depth: { _ in policy.depth(maximum: 2, lanes: 1) })
                return try Self.decoded(request)
            }
            let lanes = try zip(prompts, specs).map {
                try Self.request(stage, mtp, pool: pool, prompt: $0, outputs: $1.outputs)
            }
            var step = 0, busiest = 0, depths = Set<Int>()
            while true {
                let active = specs.indices.filter { specs[$0].start <= step && lanes[$0].tokens.count < specs[$0].outputs }
                if active.isEmpty && specs.allSatisfy({ $0.start <= step }) { break }
                step += 1
                guard !active.isEmpty else { continue }
                busiest = max(busiest, active.count)
                let windows = active.map {
                    policy.window(maximum: 2, lanes: active.count, outputLeft: specs[$0].outputs - lanes[$0].tokens.count)
                }
                depths.insert(policy.depth(maximum: 2, lanes: active.count))
                let decided = try Speculation.rounds(stage: stage, lanes: zip(active, windows).map { index, window in
                    .init(speculation: lanes[index].speculation, cache: lanes[index].cache, last: lanes[index].last,
                        window: window, stop: 0)
                })
                for (index, round) in zip(active, decided) {
                    lanes[index].tokens += round.tokens; lanes[index].last = round.tokens.last!
                }
            }
            #expect(busiest >= 3 && depths == [1, 2], "cohorts of both depths ran")
            for (lane, request) in lanes.enumerated() {
                Self.expectEqual(try Self.decoded(request), expected[lane], "lane \(lane)")
            }
        }
    }

    /// The switch changes decode-sized steps only: a prompt whose one step
    /// straddles the dense-to-sparse switch (3,000 rows) prefills to the same
    /// hidden rows and caches with it on and off, so prompt-prefix entries
    /// and SSD records do not depend on it.
    @Test(.enabled(if: enabled))
    func prefillIsTheSameWithAndWithoutTheSwitch() throws {
        try Device.withDefaultDevice(.gpu) {
            let (stage, _) = try Self.model(sharded: false)
            let vocabulary = stage.plan.configuration.vocabularySize
            let prompt = (0..<3_000).map { ($0 * 7919 + 13) % vocabulary }
            func prefill(widthInvariant: Bool) throws -> [Data] {
                stage.widthInvariantWindows = widthInvariant
                let cache = stage.newCache()
                let candidate = try stage.prepareForward(tokens: MLXArray(prompt.map(Int32.init), [1, prompt.count]),
                    cache: cache, readout: .lastToken)
                try candidate.commit(afterEvaluating: Rows.fence)
                guard case .final(let output) = candidate.output else { throw ProbeError("no readout") }
                let states = cache.layers.flatMap(\.state)
                try Rows.fence([output.hidden, output.logits] + states)
                return [Rows.bytes(output.hidden), Rows.bytes(output.logits)] + states.map(Rows.bytes)
            }
            #expect(try prefill(widthInvariant: true) == prefill(widthInvariant: false))
        }
    }

    /// Default off: without padding a request's last round (window 0)
    /// verifies one row, as before; padded it verifies two and keeps one.
    /// Both keep the same tokens before it and leave the same cache length.
    @Test(.enabled(if: enabled))
    func unpaddedLastRoundsStayOneRowWindows() throws {
        try Device.withDefaultDevice(.gpu) {
            let (stage, mtp) = try Paged.model()
            let vocabulary = stage.plan.configuration.vocabularySize
            let pool = try stage.makeDSAPagePool(pageSize: GLM5NextTensorParallelResidentRuntime.dsaPageTokens)
            let prompt = (0..<77).map { ($0 * 104_729 + 11) % vocabulary }
            let plain = try Self.request(stage, mtp, pool: pool, prompt: prompt, outputs: 6, padded: false)
            let padded = try Self.request(stage, mtp, pool: pool, prompt: prompt, outputs: 6)
            // Depth 1 to five tokens, then the sixth in a round of no proposal.
            for request in [plain, padded] {
                try Self.alone(request, stage: stage, outputs: 5, depth: { _ in 1 })
                let decided = try request.speculation.round(stage: stage, cache: request.cache, last: request.last,
                    window: 0, stop: 0)
                #expect(decided.tokens.count == 1)
                request.tokens += decided.tokens
            }
            #expect(plain.tokens.prefix(5) == padded.tokens.prefix(5))
            #expect(plain.cache.offset == padded.cache.offset && plain.cache.offset == prompt.count + 5)
            #expect(plain.speculation.keptLogits.last?.dim(1) == 1 && padded.speculation.keptLogits.last?.dim(1) == 1)
        }
    }
}
