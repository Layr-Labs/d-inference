import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

// The MiMo prompt-prefix snapshot on the tiny random MiMo model of
// `MiMoStagePipelineEquivalenceTests` (four layers: full, sliding, sliding,
// full; a window of three, shorter than the prompt), cut into the two stages
// the Plan constructs. A request runs in the frames a planned request runs
// (chunk grid, the last prompt token split off); each stage captures its
// state at the planned frontiers. A new request restored from any kept
// frontier, on both stages, must then produce the cold request's logits bit
// for bit: from the resident copies, and after the encrypted SSD record was
// written, the tier closed and opened again. A ring last written one token at
// a time is never captured. No collective and no artifact: GPU kernels on a
// tiny model only.

@Suite("MiMo prompt-prefix snapshots continue bit for bit (tiny random model)", .serialized)
struct MiMoStagePrefixSnapshotTests {
    typealias Equivalence = MiMoStagePipelineEquivalenceTests
    static let chunk = 4, stride = 8, outputs = 5

    static func stages(cut: Int) throws -> (plan: MiMoLayerStagePlan, models: [MiMoV26TextModel]) {
        let data = Equivalence.configuration(dtype: "bfloat16")
        let whole = try Equivalence.whole(data, dtype: .bfloat16)
        let plan = try MiMoLayerStagePlan(configuration: data, cut: cut)
        return (plan, try Equivalence.stages(plan, from: whole, dtype: .bfloat16))
    }

    static func globalLayers(_ plan: MiMoLayerStagePlan, _ stage: Int) -> [Int] {
        plan.stages[stage].layers.sorted { $0.localIndex < $1.localIndex }.map(\.globalIndex)
    }

    /// Frames from `start` as a planned request runs them (`frameEnds`), then
    /// greedy decode; both stages capture at their planned frontiers. Returns
    /// the logits rows (the final prompt row and one per decode step).
    static func run(_ models: [MiMoV26TextModel], plan: MiMoLayerStagePlan, caches: [[KVCache]], prompt: [Int],
                    start: Int, captures: [MiMoStagePrefixCapture]? = nil) throws -> [MLXArray] {
        let last = models[0].configuration.numHiddenLayers - 1
        func step(_ tokens: [Int], frontier: Int, prompt: Bool) throws -> MLXArray {
            let out0 = try models[0].forward(inputIDs: MLXArray(tokens.map(Int32.init)).reshaped([1, tokens.count]),
                                             cache: caches[0], captureLayers: [last])
            let residual = try #require(out0.layerFeatures[last])
            eval([residual] + caches[0].flatMap { $0.innerState() })
            if prompt { try captures?[0].capture(at: frontier, caches: caches[0], globalLayers: globalLayers(plan, 0)) }
            let received = MLXArray(residual.asData().data, residual.shape, dtype: residual.dtype)
            let row = try models[1].forward(embeddings: received, cache: caches[1], logitsStart: tokens.count - 1)
                .logits[0..., -1, 0...]
            eval([row] + caches[1].flatMap { $0.innerState() })
            if prompt { try captures?[1].capture(at: frontier, caches: caches[1], globalLayers: globalLayers(plan, 1)) }
            return row
        }
        var rows: [MLXArray] = [], offset = start
        for end in QwenLayerStageGenerationRequest.frameEnds(promptCount: prompt.count, chunkSize: chunk, start: start,
                                                             splitFinalToken: true) {
            let row = try step(Array(prompt[offset..<end]), frontier: end, prompt: true)
            offset = end
            if end == prompt.count { rows.append(row) }
        }
        while rows.count < outputs {
            let token = Int(argMax(rows[rows.count - 1], axis: -1).item(UInt32.self))
            rows.append(try step([token], frontier: offset + rows.count, prompt: false))
        }
        return rows
    }

    static func capturePlan(promptCount: Int) -> Set<Int> {
        Set(QwenLayerStageGenerationRequest.frameEnds(promptCount: promptCount, chunkSize: chunk, start: 0,
                                                      splitFinalToken: true)
            .filter { $0 == promptCount - 1 || ($0 < promptCount - 1 && $0 % stride == 0) })
    }

    static func bits(_ rows: [MLXArray]) -> [Data] { rows.map { $0.asData(access: .copy).data } }

    static func restored(_ models: [MiMoV26TextModel], plan: MiMoLayerStagePlan,
                         states: [QwenStagePrefixState]) throws -> [[KVCache]] {
        try (0..<2).map { stage in
            let caches = models[stage].newCache()
            try MiMoStagePrefixSnapshot.restore(states[stage], into: caches, globalLayers: globalLayers(plan, stage))
            return caches
        }
    }

    // Twenty-three prompt tokens in chunks of four: frames end at 4, 8, ..., 20,
    // 22 (two tokens) and 23; kept frontiers 8, 16 (grid) and 22 (the split).
    static let prompt = [5, 17, 3, 44, 96, 8, 21, 60, 2, 33, 71, 12, 9, 40, 77, 6, 58, 31, 24, 90, 15, 63, 7]

    @Test(arguments: [1, 2, 3])
    func aRestoredPairContinuesBitForBitFromEveryKeptFrontier(cut: Int) throws {
        let (plan, models) = try Self.stages(cut: cut)
        let frontiers = Self.capturePlan(promptCount: Self.prompt.count)
        #expect(frontiers == [8, 16, 22])
        let captures = [MiMoStagePrefixCapture(frontiers: frontiers), MiMoStagePrefixCapture(frontiers: frontiers)]
        let cold = try Self.run(models, plan: plan, caches: models.map { $0.newCache() }, prompt: Self.prompt, start: 0,
                                captures: captures)
        #expect(cold.allSatisfy { all(isFinite($0)).item(Bool.self) })
        let states = captures.map { $0.states() }
        #expect(states.map { $0.map(\.committedTokens) } == [[8, 16, 22], [8, 16, 22]])
        for (stage, kept) in states.enumerated() {
            for state in kept {
                // Full layers keep every committed row; sliding layers their window's tail.
                #expect(state.attention.values.allSatisfy { $0.keys.dim(2) == state.committedTokens })
                #expect(state.recurrent.values.allSatisfy { $0.conv.dim(2) == Equivalence.window
                    && $0.ssm.dim(2) == Equivalence.window })
                #expect(Set(state.attention.keys).union(state.recurrent.keys) == Set(Self.globalLayers(plan, stage)))
            }
        }
        for index in 0..<3 {
            let pair = [states[0][index], states[1][index]]
            let caches = try Self.restored(models, plan: plan, states: pair)
            let rows = try Self.run(models, plan: plan, caches: caches, prompt: Self.prompt, start: pair[0].committedTokens)
            #expect(Self.bits(rows) == Self.bits(cold), "cut \(cut) frontier \(pair[0].committedTokens)")
        }
    }

    @Test func theEncryptedSSDRecordRestoresThePairBitForBitAfterARestart() throws {
        let (plan, models) = try Self.stages(cut: 2)
        let frontiers = Self.capturePlan(promptCount: Self.prompt.count)
        let captures = [MiMoStagePrefixCapture(frontiers: frontiers), MiMoStagePrefixCapture(frontiers: frontiers)]
        let cold = try Self.run(models, plan: plan, caches: models.map { $0.newCache() }, prompt: Self.prompt, start: 0,
                                captures: captures)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mimo-prefix-ssd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var configuration = QwenStagePrefixDiskConfiguration(mode: .on(root: root, key: Data(repeating: 9, count: 32)))
        configuration.strideTokens = Self.stride; configuration.minimumTokens = 1; configuration.minimumFreeBytes = 1
        let scope = "mimo-scope|chunk=\(Self.chunk)"
        for stage in 0..<2 {
            let tier = try #require(QwenStagePrefixDiskTier.open(configuration: configuration, planScope: "mimo-plan", rank: stage))
            tier.persist(scope: scope, tokens: Self.prompt, states: captures[stage].states(), blockTokens: Self.stride)
            #expect(tier.drain(timeoutSeconds: 20))
            #expect(tier.recordCount == 1)
            tier.close()
        }
        // New processes: each rank opens its own tier and restores its own record.
        let tiers = try (0..<2).map { stage in
            try #require(QwenStagePrefixDiskTier.open(configuration: configuration, planScope: "mimo-plan", rank: stage))
        }
        for tier in tiers {
            #expect(tier.frontiers(scope: scope, tokens: Self.prompt, maximumFrontier: Self.prompt.count - 1) == [22, 16, 8])
        }
        for frontier in [22, 16, 8] {
            let states = try tiers.map { tier in
                try #require(try tier.restore(scope: scope, tokens: Self.prompt, frontier: frontier, check: {}))
            }
            let caches = try Self.restored(models, plan: plan, states: states)
            let rows = try Self.run(models, plan: plan, caches: caches, prompt: Self.prompt, start: frontier)
            #expect(Self.bits(rows) == Self.bits(cold), "SSD frontier \(frontier)")
        }
        tiers.forEach { $0.close() }
    }

    @Test func aRingWrittenOneTokenAtATimeIsNotCapturedAndNothingIsKeptWithoutTheSplitFrontier() throws {
        let (plan, models) = try Self.stages(cut: 2)
        // Twenty-two tokens: the split frontier 21 follows the one-token frame [20, 21).
        let prompt = Array(Self.prompt.prefix(22))
        let frontiers = Self.capturePlan(promptCount: prompt.count)
        #expect(frontiers == [8, 16, 21])
        let captures = [MiMoStagePrefixCapture(frontiers: frontiers), MiMoStagePrefixCapture(frontiers: frontiers)]
        _ = try Self.run(models, plan: plan, caches: models.map { $0.newCache() }, prompt: prompt, start: 0, captures: captures)
        #expect(captures.allSatisfy { $0.skipped == [21] && $0.states().isEmpty && !$0.keepsPrompt })
    }

    @Test func aRestoreRefusesAStateThatIsNotThisStagesOwn() throws {
        let (plan, models) = try Self.stages(cut: 2)
        let captures = [MiMoStagePrefixCapture(frontiers: [8, 16, 22]), MiMoStagePrefixCapture(frontiers: [8, 16, 22])]
        _ = try Self.run(models, plan: plan, caches: models.map { $0.newCache() }, prompt: Self.prompt, start: 0,
                         captures: captures)
        let own = captures[1].states()[2], other = captures[0].states()[2]
        let layers = Self.globalLayers(plan, 1)
        // Another stage's layers, a missing sliding tail, a short tail, a used cache: each refused.
        #expect(throws: (any Error).self) { try MiMoStagePrefixSnapshot.restore(other, into: models[1].newCache(), globalLayers: layers) }
        var missing = own.recurrent; missing.removeValue(forKey: missing.keys.first!)
        #expect(throws: (any Error).self) {
            try MiMoStagePrefixSnapshot.restore(.init(committedTokens: own.committedTokens, attention: own.attention, recurrent: missing),
                                                into: models[1].newCache(), globalLayers: layers)
        }
        let short = own.recurrent.mapValues { (conv: $0.conv[0..., 0..., 1..., 0...], ssm: $0.ssm[0..., 0..., 1..., 0...]) }
        #expect(throws: (any Error).self) {
            try MiMoStagePrefixSnapshot.restore(.init(committedTokens: own.committedTokens, attention: own.attention, recurrent: short),
                                                into: models[1].newCache(), globalLayers: layers)
        }
        let used = models[1].newCache()
        try MiMoStagePrefixSnapshot.restore(own, into: used, globalLayers: layers)
        #expect(throws: (any Error).self) { try MiMoStagePrefixSnapshot.restore(own, into: used, globalLayers: layers) }
    }

    @Test func aCaptureKeepsTheSplitFrontierFirstWithinItsLimit() throws {
        let (plan, models) = try Self.stages(cut: 2)
        let frontiers: Set<Int> = [8, 16, 22]
        // Measure one capture, then give the next request room for its split frontier only.
        let probe = MiMoStagePrefixCapture(frontiers: frontiers)
        _ = try Self.run(models, plan: plan, caches: models.map { $0.newCache() }, prompt: Self.prompt, start: 0,
                         captures: [probe, MiMoStagePrefixCapture(frontiers: frontiers)])
        let cost = try #require(probe.cost)
        let limited = MiMoStagePrefixCapture(frontiers: frontiers)
        limited.limitBytes = cost.bytes(deepest: 22, frontiers: 1)
        _ = try Self.run(models, plan: plan, caches: models.map { $0.newCache() }, prompt: Self.prompt, start: 0,
                         captures: [limited, MiMoStagePrefixCapture(frontiers: frontiers)])
        #expect(limited.states().map(\.committedTokens) == [22])
        let withdrawn = MiMoStagePrefixCapture(frontiers: frontiers)
        _ = try Self.run(models, plan: plan, caches: models.map { $0.newCache() }, prompt: Self.prompt, start: 0,
                         captures: [withdrawn, MiMoStagePrefixCapture(frontiers: frontiers)])
        withdrawn.withdraw()
        #expect(withdrawn.states().isEmpty && !withdrawn.keepsPrompt)
    }
}
