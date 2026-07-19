import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import Testing

@testable import ProviderCore

@Suite("Frozen-full replay real-model proof", .serialized)
struct FrozenReplayRealModelTests {
    private static let enabled =
        LiveInferenceFixtures.liveTestsEnabled
        && ProcessInfo.processInfo.environment["DARKBLOOM_FROZEN_REPLAY_REAL_MODELS"] != nil

    private struct Loaded: @unchecked Sendable {
        let container: ModelContainer
        let model: any LanguageModel
        let layerKinds: [CBv2LayerKind]
        let vocabularySize: Int
    }

    private struct State {
        let backend: CBv2ContiguousKVBackend
        let rows: [CBv2SequenceKV?]
    }

    private func loadGPTOSS() async throws -> Loaded {
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            throw LiveFixtureSkip.missingMetallib
        }
        let modelID = "mlx-community/gpt-oss-20b-MXFP4-Q8"
        guard case .found(let directory) = LiveInferenceFixtures.locate(modelID) else {
            throw LiveFixtureSkip.modelNotInCache(modelID)
        }
        LiveInferenceFixtures.applyMemoryBudget(maxBytes: 48 * 1_073_741_824)
        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: LocalTokenizerLoader())
        let snapshot = await container.perform { context in
            EngineV2ModelSnapshot(
                model: context.model,
                eosTokenIds: context.configuration.eosTokenIds,
                extraEOSTokens: context.configuration.extraEOSTokens.sorted())
        }
        let model = try #require(snapshot.model as? GPTOSSModel)
        return Loaded(
            container: container,
            model: model,
            layerKinds: model.cbv2LayerKinds,
            vocabularySize: model.vocabularySize)
    }

    private func loadGemmaQAT() async throws -> Loaded {
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            throw LiveFixtureSkip.missingMetallib
        }
        let modelID = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
        guard case .found(let directory) = LiveInferenceFixtures.locate(modelID) else {
            throw LiveFixtureSkip.modelNotInCache(modelID)
        }
        LiveInferenceFixtures.applyMemoryBudget(maxBytes: 64 * 1_073_741_824)
        let container = try await VLMModelFactory.shared.loadContainer(
            from: directory,
            using: LocalTokenizerLoader())
        let snapshot = await container.perform { context in
            EngineV2ModelSnapshot(
                model: context.model,
                eosTokenIds: context.configuration.eosTokenIds,
                extraEOSTokens: context.configuration.extraEOSTokens.sorted())
        }
        let extraction = try EngineV2VLMTextExtraction.extractTextModel(
            from: snapshot.model,
            modelDirectory: directory)
        return Loaded(
            container: container,
            model: extraction.model,
            layerKinds: extraction.model.cbv2LayerKinds,
            vocabularySize: extraction.model.vocabularySize)
    }

    private func makeBank(_ loaded: Loaded) -> CBv2LayerCacheBank {
        switch loaded.model {
        case let gpt as GPTOSSModel:
            return CBv2LayerCacheBank(caches: gpt.newCacheV2 { index, kind in
                CBv2LayerCache(layerIndex: index, kind: kind)
            })
        case let gemma as Gemma4TextModel:
            return CBv2LayerCacheBank(caches: gemma.newCacheV2 { index, kind in
                CBv2LayerCache(layerIndex: index, kind: kind)
            })
        default:
            preconditionFailure("real frozen-replay proof received unsupported model type")
        }
    }

    private func process(
        loaded: Loaded,
        state: [CBv2SequenceKV?],
        tokens: ArraySlice<Int>,
        chunkSize: Int
    ) -> MLXArray {
        let model = CBv2SteppableLanguageModelAdapter(loaded.model)
        let bank = makeBank(loaded)
        var logits = MLXArray.zeros([1, 1, loaded.vocabularySize])
        var cursor = tokens.startIndex
        while cursor < tokens.endIndex {
            let count = min(chunkSize, tokens.endIndex - cursor)
            logits = model.forward(
                tokens: MLXArray(tokens[cursor ..< cursor + count].map(Int32.init))
                    .reshaped(1, count),
                caches: bank.layerCaches(rowStates: [state]))
            eval(logits)
            cursor += count
        }
        return logits
    }

    private func coldState(
        loaded: Loaded,
        promptLength: Int,
        maxLength: Int,
        capacityBytes: Int
    ) throws -> State {
        let backend = CBv2ContiguousKVBackend(
            config: .init(bytesCapacity: capacityBytes))
        return State(
            backend: backend,
            rows: try backend.makeSequenceState(
                layerKinds: loaded.layerKinds,
                promptLength: promptLength,
                maxLength: maxLength))
    }

    private func frozenState(
        loaded: Loaded,
        donor: [CBv2SequenceKV?],
        matched: Int,
        maxLength: Int,
        capacityBytes: Int
    ) throws -> (state: State, plan: CBv2PrefixReusePlan) {
        let capability = CBv2PrefixReuseCapability.derive(
            layerKinds: loaded.layerKinds,
            backend: .contiguousUnquantized)
        let prefix = zip(loaded.layerKinds, donor).map {
            kind, row -> (keys: MLXArray, values: MLXArray, offset: Int)? in
            guard kind.sharesKVWithLayer == nil,
                case .full = kind.attention,
                let snapshot = row?.snapshot()
            else { return nil }
            return (
                snapshot.keys[.ellipsis, 0 ..< matched, 0...],
                snapshot.values[.ellipsis, 0 ..< matched, 0...],
                matched)
        }
        let exactBytes = prefix.compactMap { $0 }.reduce(0) {
            $0 + $1.keys.nbytes + $1.values.nbytes
        }
        let plan = try #require(
            capability.plan(
                matchedBoundary: matched,
                exactStagedFullKVBytes: exactBytes,
                maximumSequenceLength: maxLength))
        let backend = CBv2ContiguousKVBackend(
            config: .init(bytesCapacity: capacityBytes))
        return (
            State(
                backend: backend,
                rows: try backend.makeSequenceState(
                    adopting: prefix,
                    plan: plan,
                    layerKinds: loaded.layerKinds,
                    maxLength: maxLength)),
            plan)
    }

    private func oldMutatingState(
        loaded: Loaded,
        donor: [CBv2SequenceKV?],
        replayStart: Int,
        maxLength: Int
    ) throws -> [CBv2SequenceKV?] {
        try zip(loaded.layerKinds, donor).map { kind, row in
            guard kind.sharesKVWithLayer == nil else { return nil }
            switch kind.attention {
            case .slidingWindow(let window):
                return CBv2WindowedSequenceKV(
                    window: window,
                    kvHeads: kind.kvHeads,
                    headDim: kind.headDim,
                    initialOffset: replayStart)
            case .full:
                let snapshot = try #require(row?.snapshot())
                let resumed = CBv2FullSequenceKV(
                    promptLength: replayStart,
                    maxLength: maxLength,
                    kvHeads: kind.kvHeads,
                    headDim: kind.headDim)
                _ = resumed.update(
                    keys: snapshot.keys[.ellipsis, 0 ..< replayStart, 0...],
                    values: snapshot.values[.ellipsis, 0 ..< replayStart, 0...])
                return resumed
            }
        }
    }

    private func maxAbsDiff(_ lhs: MLXArray, _ rhs: MLXArray) -> Float {
        eval(lhs, rhs)
        return abs(lhs - rhs).max().item(Float.self)
    }

    private func greedyToken(_ logits: MLXArray) -> Int {
        logits[0, -1].argMax().item(Int.self)
    }

    private func assertFullKVBitExact(
        loaded: Loaded,
        lhs: [CBv2SequenceKV?],
        rhs: [CBv2SequenceKV?]
    ) throws {
        for (index, kind) in loaded.layerKinds.enumerated()
        where kind.sharesKVWithLayer == nil {
            guard case .full = kind.attention else { continue }
            let left = try #require(lhs[index]?.snapshot())
            let right = try #require(rhs[index]?.snapshot())
            #expect(left.offset == right.offset)
            #expect(maxAbsDiff(left.keys, right.keys) == 0)
            #expect(maxAbsDiff(left.values, right.values) == 0)
        }
    }

    private func assertGreedyContinuationBitExact(
        loaded: Loaded,
        cold: State,
        frozen: State,
        coldLogits initialCold: MLXArray,
        frozenLogits initialFrozen: MLXArray,
        count: Int
    ) {
        var coldLogits = initialCold
        var frozenLogits = initialFrozen
        var coldTokens: [Int] = []
        var frozenTokens: [Int] = []
        for _ in 0 ..< count {
            let coldToken = greedyToken(coldLogits)
            let frozenToken = greedyToken(frozenLogits)
            coldTokens.append(coldToken)
            frozenTokens.append(frozenToken)
            #expect(coldToken == frozenToken)
            coldLogits = process(
                loaded: loaded,
                state: cold.rows,
                tokens: [coldToken][...],
                chunkSize: 1)
            frozenLogits = process(
                loaded: loaded,
                state: frozen.rows,
                tokens: [frozenToken][...],
                chunkSize: 1)
            #expect(maxAbsDiff(coldLogits, frozenLogits) == 0)
        }
        #expect(coldTokens == frozenTokens)
    }

    @Test(
        "real GPT-OSS 2,817-token counterexample: old drift 0.20875001, frozen logits/KV/tokens exact",
        .enabled(if: Self.enabled))
    func realGPTOSSCounterexample() async throws {
        let loaded = try await loadGPTOSS()
        let promptLength = 2_817
        let prompt = (0 ..< promptLength).map {
            1_000 + ($0 * 7_919) % 50_000
        }
        let matched = 2_816
        let maxLength = promptLength + 128
        let cold = try coldState(
            loaded: loaded,
            promptLength: promptLength,
            maxLength: maxLength,
            capacityBytes: 2 << 30)
        let coldStarted = CFAbsoluteTimeGetCurrent()
        var coldLogits = process(
            loaded: loaded,
            state: cold.rows,
            tokens: prompt[...],
            chunkSize: 128)
        let coldSeconds = CFAbsoluteTimeGetCurrent() - coldStarted
        let (frozen, plan) = try frozenState(
            loaded: loaded,
            donor: cold.rows,
            matched: matched,
            maxLength: maxLength,
            capacityBytes: 2 << 30)
        #expect(plan.replayTokens == 1_536)
        #expect(plan.replayStart == 1_280)
        let frozenStarted = CFAbsoluteTimeGetCurrent()
        var frozenLogits = process(
            loaded: loaded,
            state: frozen.rows,
            tokens: prompt[plan.replayStart...],
            chunkSize: 128)
        let frozenSeconds = CFAbsoluteTimeGetCurrent() - frozenStarted

        let oldRows = try oldMutatingState(
            loaded: loaded,
            donor: cold.rows,
            replayStart: plan.replayStart,
            maxLength: maxLength)
        let oldLogits = process(
            loaded: loaded,
            state: oldRows,
            tokens: prompt[plan.replayStart...],
            chunkSize: 128)
        let oldDrift = maxAbsDiff(coldLogits, oldLogits)
        let firstFullIndex = try #require(loaded.layerKinds.firstIndex { kind in
            guard kind.sharesKVWithLayer == nil else { return false }
            if case .full = kind.attention { return true }
            return false
        })
        let firstFull = try #require(cold.rows[firstFullIndex]?.snapshot())
        print(
            "[frozen-real-gptoss] prompt=\(promptLength) M=\(matched) "
                + "R=\(plan.replayTokens) saved=\(plan.prefillTokensSaved) "
                + "cold_s=\(coldSeconds) frozen_replay_s=\(frozenSeconds) "
                + "old_max_abs=\(oldDrift) frozen_max_abs="
                + "\(maxAbsDiff(coldLogits, frozenLogits)) "
                + "full_k_dtype=\(firstFull.keys.dtype) "
                + "full_v_dtype=\(firstFull.values.dtype) "
                + "exact_full_bytes_per_token=\(plan.fullKVBytesPerToken)")
        #expect(abs(oldDrift - 0.20875001) < 0.00001)
        #expect(maxAbsDiff(coldLogits, frozenLogits) == 0)
        #expect(frozenSeconds < coldSeconds)
        try assertFullKVBitExact(
            loaded: loaded,
            lhs: cold.rows,
            rhs: frozen.rows)

        for _ in 0 ..< 64 {
            let coldToken = greedyToken(coldLogits)
            let frozenToken = greedyToken(frozenLogits)
            #expect(coldToken == frozenToken)
            coldLogits = process(
                loaded: loaded,
                state: cold.rows,
                tokens: [coldToken][...],
                chunkSize: 1)
            frozenLogits = process(
                loaded: loaded,
                state: frozen.rows,
                tokens: [frozenToken][...],
                chunkSize: 1)
            #expect(maxAbsDiff(coldLogits, frozenLogits) == 0)
        }

        cold.backend.release(cold.rows)
        frozen.backend.release(frozen.rows)
        #expect(cold.backend.bytesReserved == 0)
        #expect(frozen.backend.bytesReserved == 0)
        MLX.Memory.clearCache()
        _ = loaded.container
    }

    @Test(
        "real GPT-OSS 4k/8k benefit curve remains raw-logit exact",
        .enabled(if: Self.enabled))
    func realGPTOSSBenefitCurve() async throws {
        let loaded = try await loadGPTOSS()
        for promptLength in [4_097, 8_193] {
            let prompt = (0 ..< promptLength).map {
                1_000 + ($0 * 7_919) % 50_000
            }
            let matched = ((promptLength - 1) / 256) * 256
            let maxLength = promptLength + 32
            let cold = try coldState(
                loaded: loaded,
                promptLength: promptLength,
                maxLength: maxLength,
                capacityBytes: 4 << 30)
            let coldStarted = CFAbsoluteTimeGetCurrent()
            let coldLogits = process(
                loaded: loaded,
                state: cold.rows,
                tokens: prompt[...],
                chunkSize: 128)
            let coldSeconds = CFAbsoluteTimeGetCurrent() - coldStarted
            let (frozen, plan) = try frozenState(
                loaded: loaded,
                donor: cold.rows,
                matched: matched,
                maxLength: maxLength,
                capacityBytes: 4 << 30)
            let frozenStarted = CFAbsoluteTimeGetCurrent()
            let frozenLogits = process(
                loaded: loaded,
                state: frozen.rows,
                tokens: prompt[plan.replayStart...],
                chunkSize: 128)
            let frozenSeconds = CFAbsoluteTimeGetCurrent() - frozenStarted
            #expect(maxAbsDiff(coldLogits, frozenLogits) == 0)
            #expect(frozenSeconds <= coldSeconds * 0.8)
            print(
                "[frozen-real-gptoss-curve] prompt=\(promptLength) M=\(matched) "
                    + "R=\(plan.replayTokens) saved=\(plan.prefillTokensSaved) "
                    + "cold_s=\(coldSeconds) frozen_replay_s=\(frozenSeconds)")
            cold.backend.release(cold.rows)
            frozen.backend.release(frozen.rows)
            #expect(cold.backend.bytesReserved == 0)
            #expect(frozen.backend.bytesReserved == 0)
            MLX.Memory.clearCache()
        }
        _ = loaded.container
    }

    @Test(
        "real Gemma QAT: raw logits and 128 greedy tokens exact across long prompts",
        .enabled(if: Self.enabled))
    func realGemmaQATLongContexts() async throws {
        let loaded = try await loadGemmaQAT()
        let capacityBytes = 8 << 30
        for promptLength in [26_625, 26_881, 27_137] {
            let prompt = (0 ..< promptLength).map {
                1_000 + ($0 * 7_919) % max(2, loaded.vocabularySize - 1_000)
            }
            let matched = ((promptLength - 1) / 256) * 256
            let maxLength = promptLength + 160
            let cold = try coldState(
                loaded: loaded,
                promptLength: promptLength,
                maxLength: maxLength,
                capacityBytes: capacityBytes)
            let coldStarted = CFAbsoluteTimeGetCurrent()
            let coldLogits = process(
                loaded: loaded,
                state: cold.rows,
                tokens: prompt[...],
                chunkSize: 256)
            let coldSeconds = CFAbsoluteTimeGetCurrent() - coldStarted
            let (frozen, plan) = try frozenState(
                loaded: loaded,
                donor: cold.rows,
                matched: matched,
                maxLength: maxLength,
                capacityBytes: capacityBytes)
            #expect(plan.strategy == .frozenFullReplay)
            #expect(plan.replayTokens == 25_600)
            #expect(plan.replayStart == matched - 25_600)
            let frozenStarted = CFAbsoluteTimeGetCurrent()
            let frozenLogits = process(
                loaded: loaded,
                state: frozen.rows,
                tokens: prompt[plan.replayStart...],
                chunkSize: 256)
            let frozenSeconds = CFAbsoluteTimeGetCurrent() - frozenStarted
            print(
                "[frozen-real-gemma] prompt=\(promptLength) M=\(matched) "
                    + "R=\(plan.replayTokens) saved=\(plan.prefillTokensSaved) "
                    + "cold_s=\(coldSeconds) frozen_replay_s=\(frozenSeconds) "
                    + "frozen_max_abs=\(maxAbsDiff(coldLogits, frozenLogits))")
            #expect(maxAbsDiff(coldLogits, frozenLogits) == 0)
            try assertFullKVBitExact(
                loaded: loaded,
                lhs: cold.rows,
                rhs: frozen.rows)
            assertGreedyContinuationBitExact(
                loaded: loaded,
                cold: cold,
                frozen: frozen,
                coldLogits: coldLogits,
                frozenLogits: frozenLogits,
                count: 128)

            cold.backend.release(cold.rows)
            frozen.backend.release(frozen.rows)
            #expect(cold.backend.bytesReserved == 0)
            #expect(frozen.backend.bytesReserved == 0)
            MLX.Memory.clearCache()
        }
        _ = loaded.container
    }

    @Test(
        "real Gemma QAT 32k benefit point remains raw-logit exact",
        .enabled(if: Self.enabled))
    func realGemmaQAT32KBenefit() async throws {
        let loaded = try await loadGemmaQAT()
        let promptLength = 32_769
        let prompt = (0 ..< promptLength).map {
            1_000 + ($0 * 7_919) % max(2, loaded.vocabularySize - 1_000)
        }
        let matched = 32_768
        let maxLength = promptLength + 32
        let capacityBytes = 8 << 30
        let cold = try coldState(
            loaded: loaded,
            promptLength: promptLength,
            maxLength: maxLength,
            capacityBytes: capacityBytes)
        let coldStarted = CFAbsoluteTimeGetCurrent()
        let coldLogits = process(
            loaded: loaded,
            state: cold.rows,
            tokens: prompt[...],
            chunkSize: 256)
        let coldSeconds = CFAbsoluteTimeGetCurrent() - coldStarted
        let (frozen, plan) = try frozenState(
            loaded: loaded,
            donor: cold.rows,
            matched: matched,
            maxLength: maxLength,
            capacityBytes: capacityBytes)
        let frozenStarted = CFAbsoluteTimeGetCurrent()
        let frozenLogits = process(
            loaded: loaded,
            state: frozen.rows,
            tokens: prompt[plan.replayStart...],
            chunkSize: 256)
        let frozenSeconds = CFAbsoluteTimeGetCurrent() - frozenStarted
        #expect(plan.replayTokens == 25_600)
        #expect(plan.prefillTokensSaved == 7_168)
        #expect(maxAbsDiff(coldLogits, frozenLogits) == 0)
        #expect(frozenSeconds <= coldSeconds * 0.85)
        print(
            "[frozen-real-gemma-curve] prompt=\(promptLength) M=\(matched) "
                + "R=\(plan.replayTokens) saved=\(plan.prefillTokensSaved) "
                + "cold_s=\(coldSeconds) frozen_replay_s=\(frozenSeconds)")
        cold.backend.release(cold.rows)
        frozen.backend.release(frozen.rows)
        #expect(cold.backend.bytesReserved == 0)
        #expect(frozen.backend.bytesReserved == 0)
        MLX.Memory.clearCache()
        _ = loaded.container
    }
}
