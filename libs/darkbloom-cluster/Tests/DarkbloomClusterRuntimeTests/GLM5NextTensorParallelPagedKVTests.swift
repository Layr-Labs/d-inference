import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

/// Paged KV for GLM tensor parallel (`GLM5NextTensorParallelPagedKV.swift`).
///
/// Model-free: the reservation a request makes and the load agreement.
///
/// Opt-in (`GLM53_PAGED_KV=1`, GPU, the synthetic serving-policy stage and
/// NextN layer of `GLM5NextTensorParallelSpeculationRowsTests`): requests
/// whose DSA and NextN histories live in a page pool decide exactly the
/// rounds (tokens, proposals, keeps), and leave exactly the caches and NextN
/// histories, of the same requests with contiguous histories, alone and
/// batched (`rounds`); a prompt prefix shared by page continues exactly as a
/// prefilled one; and every page comes back.
@Suite(.serialized)
struct GLM5NextTensorParallelPagedKVTests {
    typealias Runtime = GLM5NextTensorParallelResidentRuntime
    typealias Rows = GLM5NextTensorParallelSpeculationRowsTests
    static let enabled = ProcessInfo.processInfo.environment["GLM53_PAGED_KV"] == "1"

    @Test func pagedKVIsTheDefaultAndBoundIntoTheAgreement() throws {
        #expect(try Runtime.pagedKV([:]))
        #expect(try Runtime.pagedKV(["DARKBLOOM_CLUSTER_GLM_PAGED_KV": "1"]))
        #expect(try !Runtime.pagedKV(["DARKBLOOM_CLUSTER_GLM_PAGED_KV": "0"]))
        #expect(throws: ProbeError.self) { try Runtime.pagedKV(["DARKBLOOM_CLUSTER_GLM_PAGED_KV": "yes"]) }
        #expect(Runtime.pagedKVAgreementFields(true) == ["glm5-next-tp-paged-kv-v1", "page=64"])
        #expect(Runtime.pagedKVAgreementFields(false) == ["glm5-next-tp-paged-kv-v1", "contiguous"])
    }

    /// A request reserves every DSA layer's history and the NextN history at
    /// its own context plus a verification window, one page each beside them
    /// for a copy on write; a paged lane is not charged the histories again.
    @Test func aRequestReservesItsHistoriesPages() throws {
        let declared = try Rows.configuration()
        let c = declared.textConfig
        let pool = try GLM5NextDSAPagePool(pageSize: 64, latentWidth: c.kvLoraRank, keyWidth: c.indexHeadDim,
            latentType: .bfloat16, keyType: .bfloat16, gateType: .bfloat16)
        let dsa = c.layerTypes.filter { $0 == .deepseekSparseAttention }.count
        #expect(pool.pages(tokens: 0) == 0 && pool.pages(tokens: 1) == 2 && pool.pages(tokens: 64) == 2
            && pool.pages(tokens: 65) == 3)
        #expect(Runtime.historyPages(pool: pool, configuration: c, contextTokens: 1000, speculative: false)
            == dsa * 17)
        #expect(Runtime.historyPages(pool: pool, configuration: c, contextTokens: 1000, speculative: true)
            == (dsa + 1) * 17)
        #expect(pool.pageBytes == 64 * (512 * 2 + 128 * 2 * 2 + 1))
        // The real model at its native context: 11 DSA layers and the NextN layer.
        let native = 12 * pool.pages(tokens: 1_048_576 + 3) * pool.pageBytes
        #expect(native < 20 << 30)
        let paged = try Runtime.laneStateBytes(configuration: c, contextTokens: 32_768, speculative: true,
            pagedHistories: true)
        let contiguous = try Runtime.laneStateBytes(configuration: c, contextTokens: 32_768, speculative: true)
        #expect(paged < contiguous)
        #expect(try Runtime.laneStateBytes(configuration: c, contextTokens: 64, speculative: true,
            pagedHistories: true) == paged)
    }

    /// A paged request's charge (`GLM5NextTensorParallelRequestCharge.pagedHistory`)
    /// holds its pages (every DSA history at its own length, in 64-token
    /// pages, plus the copy-on-write page) instead of every history twice,
    /// and one layer's gathered history per stage that has DSA layers
    /// (`GLM5NextRequestStateBudget.HistoryBound.paged`); every other term is
    /// the contiguous charge's. Page bytes are FP32 rows until the pool gives its own.
    @Test func aPagedRequestIsChargedItsPages() throws {
        let fixture = try GLM5NextResidentRuntimeTests.Fixture()
        let d = fixture.descriptor
        let envelopes = try (0...1).map {
            try GLM5NextResidentRuntimeTests.Fixture.resources(descriptor: d, inventory: fixture.artifact.metadata.inventory,
                rank: $0)
        }
        let contiguous = try GLM5NextTensorParallelRequestCharge(descriptor: d, envelopes: envelopes, fixedBytes: 1000,
            speculativeDepth: 0, maximumBufferBytes: Int.max, allocationBound: { $0 })
        let c = d.configuration.textConfig
        var paged = contiguous
        paged.pagedHistory = .init(configuration: c, pageTokens: 64)
        let row = c.kvLoraRank * 4 + 2 * c.indexHeadDim * 4 + 1
        let dsa = c.layerTypes.filter { $0 == .deepseekSparseAttention }.count
        let stages = [0 ..< d.cut, d.cut ..< c.hiddenLayers].filter { layers in
            layers.contains { c.layerTypes[$0] == .deepseekSparseAttention }
        }.count
        #expect(dsa > 0 && paged.pagedHistory?.pageBytes == 64 * row)
        for context in [2, 63, 127, 255] {
            let pages = (context + 1 + 63) / 64 + 1
            #expect(try paged.pagedHistoryBytes(contextTokens: context) == dsa * pages * 64 * row)
            #expect(try contiguous.pagedHistoryBytes(contextTokens: context) == 0)
        }
        // From 128 to 256 history tokens: two more pages per history and 128
        // more gathered rows (twice) per stage, instead of 128 rows twice per history.
        let growth = try paged.bytes(contextTokens: 255) - paged.bytes(contextTokens: 127)
        let capped = try contiguous.bytes(contextTokens: 255) - contiguous.bytes(contextTokens: 127)
        #expect(growth == capped - 128 * row * 2 * dsa + dsa * 2 * 64 * row + 128 * row * 2 * stages)
    }

    /// One request as the runtime runs it, with paged or contiguous histories.
    final class Request {
        let cache: GLM5NextTextStageCache
        let speculation: GLM5NextTensorParallelSpeculation
        let pages: GLM5NextTensorParallelPageReservation?
        var last: Int
        var tokens: [Int] = []

        /// `embeddings`: a media request's input embeddings `[1, prompt.count, H]`
        /// (feature rows spliced over token rows): its frames run from them in
        /// two micro-batches and prime the NextN history with them, as the
        /// runtime's media frames (`runPrefillFrame`).
        init(stage: GLM5NextTextStage, mtp: GLM5NextMTP, pool: GLM5NextDSAPagePool?, prompt: [Int],
             outputs: Int, restoring: (cache: GLM5NextTextStageCache, mtp: GLM5NextMTPCheckpoint?, length: Int)? = nil,
             embeddings: MLXArray? = nil,
             store: ((Int, GLM5NextTextStageCache, GLM5NextMTPCheckpoint) -> Void)? = nil) throws {
            pages = try pool.map { pool in
                GLM5NextTensorParallelPageReservation(pool: pool, account: try pool.reserve(pages:
                    Runtime.historyPages(pool: pool, configuration: stage.plan.configuration,
                        contextTokens: prompt.count + outputs + 3, speculative: true)))
            }
            let speculation = try GLM5NextTensorParallelSpeculation(mtp: mtp, depth: 2, rank: 0, ranks: 1,
                primeRows: 512, pagePool: pool, pageAccount: pages?.account, agree: { $0 })
            self.speculation = speculation
            // The stage makes paged caches while it has the pool.
            let saved = stage.dsaPagePool
            stage.dsaPagePool = pool
            defer { stage.dsaPagePool = saved }
            var cache = stage.newCache(account: pages?.account)
            var start = 0
            if let restoring {
                cache = restoring.cache.copy()
                cache.bindPages(to: pages?.account)
                try speculation.restore(restoring.mtp)
                start = restoring.length
            }
            self.cache = cache
            var final: GLM5NextTextOutput?
            // Frames of 600 tokens (boundaries inside a page), one grid for every request.
            for begin in stride(from: start, to: prompt.count, by: 600) {
                let end = min(prompt.count, begin + 600)
                let readout: GLM5NextTextStageReadout = end == prompt.count ? .allTokens : .none
                let candidate = try embeddings.map {
                    try stage.prepareForward(embeddings: $0[0..., begin ..< end], cache: cache,
                        segments: [.chunk(tokens: end - begin, microBatches: 2)], readout: readout)
                } ?? stage.prepareForward(tokens: MLXArray(prompt[begin ..< end].map(Int32.init),
                    [1, end - begin]), cache: cache, readout: readout)
                let inputs = embeddings.map { rows in { (lower: Int, upper: Int) throws -> MLXArray? in
                    rows[0..., lower ..< upper] } }
                switch candidate.output {
                case .final(let output):
                    try speculation.primePrompt(prompt, from: begin, to: end, hidden: output.hidden, inputs: inputs)
                    final = output
                case .hidden(let hidden):
                    try speculation.primePrompt(prompt, from: begin, to: end, hidden: hidden, inputs: inputs)
                case .streams: throw ProbeError("no hidden rows")
                }
                try candidate.commit { roots in try Rows.fence(roots + (try speculation.evaluationTargets())) }
                if end < prompt.count, let store { store(end, cache, try speculation.checkpoint()) }
            }
            guard let final else { throw ProbeError("no readout") }
            last = Int(argMax(final.logits[0, -1].asType(.float32), axis: -1).item(Int32.self))
            try speculation.begin(carry: last, lastHidden: final.hidden[0..., (-1)..., 0...])
        }
    }

    static func expectSame(_ a: Request, _ b: Request, _ label: String) throws {
        #expect(a.tokens == b.tokens, "\(label) tokens")
        #expect(a.cache.offset == b.cache.offset, "\(label) offset")
        let left = a.cache.layers.flatMap(\.state), right = b.cache.layers.flatMap(\.state)
        #expect(left.count == right.count, "\(label) state count")
        for (index, (x, y)) in zip(left, right).enumerated() {
            #expect(x.dtype == y.dtype && Rows.bytes(x) == Rows.bytes(y), "\(label) state \(index)")
        }
        let history = a.speculation.state.history, own = b.speculation.state.history
        try Rows.fence(history + own)
        #expect(history.count == own.count, "\(label) NextN history count")
        for (x, y) in zip(history, own) { #expect(Rows.bytes(x) == Rows.bytes(y), "\(label) NextN history") }
        #expect(a.speculation.rounds == b.speculation.rounds
            && a.speculation.acceptedTokens == b.speculation.acceptedTokens
            && a.speculation.proposedTokens == b.speculation.proposedTokens, "\(label) counters")
    }

    /// The synthetic serving stage and its NextN layer (`GLM5NextTensorParallelSpeculationRowsTests`).
    static func model() throws -> (stage: GLM5NextTextStage, mtp: GLM5NextMTP) {
        let declared = try Rows.configuration()
        let inventory = try GLM5NextWeightInventory.validate(configuration: declared,
            tensors: GLM5NextWeightInventory.expectedTensors(configuration: declared, storage: .nvfp4Hybrid,
                shard: "rows.safetensors"), storage: .nvfp4Hybrid)
        let resolve: (String) throws -> MLXArray = { name in
            guard let entry = inventory.entries[name] else { throw ProbeError("missing \(name)") }
            return Rows.tensor(entry)
        }
        let text = declared.textConfig
        let stage = try GLM5NextTextStage(plan: .init(configuration: text, layers: 0 ..< text.hiddenLayers),
            inventory: inventory, tensor: resolve, materializeExpertStack: { eval($0) },
            releaseSourceTensors: { _ in }, executionPolicy: .serving, materializeFusedProjections: { eval($0) })
        let mtp = try GLM5NextMTP(stage: stage, tensor: resolve, materializeExpertStack: { eval($0) },
            releaseSourceTensors: { _ in }, materializeFusedProjections: { eval($0) })
        return (stage, mtp)
    }

    /// Media requests (image or video feature rows in the prompt, the media
    /// lanes' frames: input embeddings in micro-batched segments, NextN
    /// priming from the same rows) with paged histories decide exactly the
    /// rounds, and hold exactly the caches and NextN histories, of the same
    /// requests with contiguous ones, alone and batched with a text request.
    @Test(.enabled(if: enabled))
    func pagedMediaRequestsDecideAndHoldWhatContiguousOnesDo() throws {
        try Device.withDefaultDevice(.gpu) {
            let (stage, mtp) = try Self.model()
            let text = stage.plan.configuration
            let embedding = try #require(stage.embedding)
            let pool = try stage.makeDSAPagePool(pageSize: Runtime.dsaPageTokens)
            let outputs = 18
            // Feature rows across frame (600) and page (64) boundaries; one text request beside them.
            let shapes: [(length: Int, media: [Range<Int>])] = [
                (1_300, [5 ..< 70, 590 ..< 910]), (2_100, [0 ..< 64, 1_150 ..< 1_420, 2_000 ..< 2_099]), (420, []),
            ]
            let prompts = shapes.enumerated().map { lane, shape in
                (0..<shape.length).map { (($0 + 11) * 7919 + lane * 104_729) % text.vocabularySize }
            }
            let inputs = try zip(prompts, shapes).enumerated().map { lane, entry -> MLXArray? in
                let (prompt, shape) = entry
                guard !shape.media.isEmpty else { return nil }
                let rows = embedding(MLXArray(prompt.map(Int32.init), [1, prompt.count]))
                let features = MLXRandom.normal([1, prompt.count, text.hiddenSize], key: MLXRandom.key(UInt64(lane + 3)))
                    .asType(rows.dtype)
                var pieces: [MLXArray] = [], at = 0
                for range in shape.media {
                    if range.lowerBound > at { pieces.append(rows[0..., at ..< range.lowerBound]) }
                    pieces.append(features[0..., range]); at = range.upperBound
                }
                if at < prompt.count { pieces.append(rows[0..., at...]) }
                let spliced = concatenated(pieces, axis: 1)
                try Rows.fence([spliced])
                return spliced
            }
            let contiguous = try zip(prompts, inputs).map {
                try Request(stage: stage, mtp: mtp, pool: nil, prompt: $0, outputs: outputs, embeddings: $1)
            }
            let alone = try zip(prompts, inputs).map {
                try Request(stage: stage, mtp: mtp, pool: pool, prompt: $0, outputs: outputs, embeddings: $1)
            }
            let batched = try zip(prompts, inputs).map {
                try Request(stage: stage, mtp: mtp, pool: pool, prompt: $0, outputs: outputs, embeddings: $1)
            }
            for (lane, (a, b)) in zip(alone, contiguous).enumerated() { try Self.expectSame(a, b, "media prefill lane \(lane)") }
            for round in 0..<5 {
                let windows = (0..<prompts.count).map { lane in round == 4 && lane == 1 ? 0 : 2 }
                let decided = try GLM5NextTensorParallelSpeculation.rounds(stage: stage, lanes: zip(batched, windows).map {
                    .init(speculation: $0.speculation, cache: $0.cache, last: $0.last, window: $1, stop: 0)
                })
                for lane in prompts.indices {
                    let reference = try contiguous[lane].speculation.round(stage: stage, cache: contiguous[lane].cache,
                        last: contiguous[lane].last, window: windows[lane], stop: 0)
                    let paged = try alone[lane].speculation.round(stage: stage, cache: alone[lane].cache,
                        last: alone[lane].last, window: windows[lane], stop: 0)
                    #expect(paged == reference, "media round \(round) lane \(lane) alone")
                    #expect(decided[lane] == reference, "media round \(round) lane \(lane) batched")
                    for (request, value) in [(contiguous[lane], reference), (alone[lane], paged),
                                             (batched[lane], decided[lane])] {
                        request.tokens += value.tokens; request.last = value.tokens.last!
                    }
                }
            }
            for lane in prompts.indices {
                try Self.expectSame(alone[lane], contiguous[lane], "media lane \(lane) alone")
                try Self.expectSame(batched[lane], contiguous[lane], "media lane \(lane) batched")
            }
            _ = (contiguous, alone, batched)
            #expect(pool.allocatedPages > 0)
            // The feature rows reached the histories: a media request's
            // prefill leaves other caches than its text twin's.
            let media = try Request(stage: stage, mtp: mtp, pool: pool, prompt: prompts[1], outputs: outputs,
                embeddings: inputs[1])
            let twin = try Request(stage: stage, mtp: mtp, pool: pool, prompt: prompts[1], outputs: outputs)
            let states = (media.cache.layers.flatMap(\.state), twin.cache.layers.flatMap(\.state))
            #expect(zip(states.0, states.1).contains { Rows.bytes($0) != Rows.bytes($1) }, "media rows had no effect")
        }
    }

    @Test(.enabled(if: enabled))
    func pagedRequestsDecideAndHoldWhatContiguousOnesDo() throws {
        try Device.withDefaultDevice(.gpu) {
            let declared = try Rows.configuration()
            let inventory = try GLM5NextWeightInventory.validate(configuration: declared,
                tensors: GLM5NextWeightInventory.expectedTensors(configuration: declared, storage: .nvfp4Hybrid,
                    shard: "rows.safetensors"), storage: .nvfp4Hybrid)
            let resolve: (String) throws -> MLXArray = { name in
                guard let entry = inventory.entries[name] else { throw ProbeError("missing \(name)") }
                return Rows.tensor(entry)
            }
            let text = declared.textConfig
            let stage = try GLM5NextTextStage(plan: .init(configuration: text, layers: 0 ..< text.hiddenLayers),
                inventory: inventory, tensor: resolve, materializeExpertStack: { eval($0) },
                releaseSourceTensors: { _ in }, executionPolicy: .serving, materializeFusedProjections: { eval($0) })
            let mtp = try GLM5NextMTP(stage: stage, tensor: resolve, materializeExpertStack: { eval($0) },
                releaseSourceTensors: { _ in }, materializeFusedProjections: { eval($0) })
            let pool = try stage.makeDSAPagePool(pageSize: Runtime.dsaPageTokens)
            // The last two are long enough that decode reads only selected
            // latents (the target's DSA layers and the NextN layer).
            let lengths = [7, 300, 41, 2_061, 650, 12_400, 13_100]
            let outputs = 24
            let prompts = lengths.enumerated().map { lane, length in
                (0..<length).map { (($0 + 3) * 7919 + lane * 104_729) % text.vocabularySize }
            }
            let contiguous = try prompts.map { try Request(stage: stage, mtp: mtp, pool: nil, prompt: $0, outputs: outputs) }
            let alone = try prompts.map { try Request(stage: stage, mtp: mtp, pool: pool, prompt: $0, outputs: outputs) }
            let batched = try prompts.map { try Request(stage: stage, mtp: mtp, pool: pool, prompt: $0, outputs: outputs) }
            for (lane, (a, b)) in zip(alone, contiguous).enumerated() { try Self.expectSame(a, b, "prefill lane \(lane)") }
            for round in 0..<6 {
                let windows = (0..<prompts.count).map { lane in round == 5 && lane % 2 == 1 ? 0 : 2 }
                let decided = try GLM5NextTensorParallelSpeculation.rounds(stage: stage, lanes: zip(batched, windows).map {
                    .init(speculation: $0.speculation, cache: $0.cache, last: $0.last, window: $1, stop: 0)
                })
                for lane in prompts.indices {
                    let reference = try contiguous[lane].speculation.round(stage: stage, cache: contiguous[lane].cache,
                        last: contiguous[lane].last, window: windows[lane], stop: 0)
                    let paged = try alone[lane].speculation.round(stage: stage, cache: alone[lane].cache,
                        last: alone[lane].last, window: windows[lane], stop: 0)
                    #expect(paged == reference, "round \(round) lane \(lane) alone")
                    #expect(decided[lane] == reference, "round \(round) lane \(lane) batched")
                    for (request, value) in [(contiguous[lane], reference), (alone[lane], paged),
                                             (batched[lane], decided[lane])] {
                        request.tokens += value.tokens; request.last = value.tokens.last!
                    }
                }
            }
            for lane in prompts.indices {
                try Self.expectSame(alone[lane], contiguous[lane], "lane \(lane) alone")
                try Self.expectSame(batched[lane], contiguous[lane], "lane \(lane) batched")
            }
            #expect(pool.allocatedPages > 0)

            // A prompt prefix shared by page: the runtime's prefix cache keeps
            // the paged request's state at a frame boundary; two requests
            // restored from it go on exactly as a request that prefilled the
            // whole prompt (contiguous), while the storing request goes on too.
            let prefix = GLM5NextTensorParallelPrefixCache(budgetBytes: 8 << 30)
            let prompt = (0..<1_500).map { ($0 * 104_729 + 17) % text.vocabularySize }
            let scope = "paged-kv-test"
            let storing = try Request(stage: stage, mtp: mtp, pool: pool, prompt: prompt, outputs: outputs,
                store: { length, cache, checkpoint in
                    prefix.store(scope: scope, prompt: prompt, length: length, cache: cache, mtp: checkpoint)
                })
            #expect(prefix.count == 2 && prefix.bytesInUse > 0)
            let whole = try Request(stage: stage, mtp: mtp, pool: nil, prompt: prompt, outputs: outputs)
            let restored = try (0..<2).map { _ -> Request in
                let entry = try #require(prefix.restore(scope: scope, prompt: prompt, length: 1_200))
                return try Request(stage: stage, mtp: mtp, pool: pool, prompt: prompt, outputs: outputs,
                    restoring: (entry.cache, entry.mtp, 1_200))
            }
            for round in 0..<4 {
                let reference = try whole.speculation.round(stage: stage, cache: whole.cache, last: whole.last,
                    window: 2, stop: 0)
                whole.tokens += reference.tokens; whole.last = reference.tokens.last!
                for (index, request) in ([storing] + restored).enumerated() {
                    let value = try request.speculation.round(stage: stage, cache: request.cache, last: request.last,
                        window: 2, stop: 0)
                    #expect(value == reference, "shared prefix request \(index) round \(round)")
                    request.tokens += value.tokens; request.last = value.tokens.last!
                }
            }
            for (index, request) in ([storing] + restored).enumerated() {
                try Self.expectSame(request, whole, "shared prefix request \(index)")
            }
            // Pages: the entries hold theirs after the requests go; a sweep
            // gives every page back.
            let held = pool.allocatedPages
            #expect(held > 0)
            _ = (contiguous, alone, batched, storing, restored)
        }
    }
}
