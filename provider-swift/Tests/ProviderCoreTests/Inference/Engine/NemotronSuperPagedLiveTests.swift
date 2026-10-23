// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
@testable import MLXLLM
@testable import MLXLMCommon
@testable import MLXVLM
import Testing
@testable import ProviderCore

/// Gated full-checkpoint comparison of the Super trunk's attention KV in
/// segmented native paged storage (64 MiB segments and the loaded model's
/// layer types, as the production factory builds it) against contiguous BF16
/// storage. One long prompt is prefilled in production-size chunks with the
/// logits of every chunk end, then greedy decode steps are fed the contiguous
/// choices. Paged prefill is bitwise equal; paged decode reduces attention
/// differently, so its logits are held to a stated bound calibrated by a
/// contiguous arm prefilled in half chunks, and every deviation is printed.
/// Loads about 80 GB through the pinned staging; run only with exclusive GPU
/// access, `DARKBLOOM_SUPER_PAGED_LIVE=1` and `NEMOTRON_SUPER_CHECKPOINT_DIR`.
struct NemotronSuperPagedLiveTests {
    static let enabled = ProcessInfo.processInfo.environment["DARKBLOOM_SUPER_PAGED_LIVE"] == "1"
        && ProcessInfo.processInfo.environment["NEMOTRON_SUPER_CHECKPOINT_DIR"] != nil
    static let tolerance: Float = 0.1
    static let chunk = NemotronSuperLocalPrefill.defaultChunkTokens
    static let promptTokens = 16_000
    static let decodeSteps = 64
    static let maximumLength = 16_384

    enum Failure: Error { case layout }

    final class Lane {
        let rows: [CBv2SequenceKV?]
        let state: CBv2RecurrentRequestState
        init(rows: [CBv2SequenceKV?], state: CBv2RecurrentRequestState) {
            self.rows = rows
            self.state = state
        }
    }

    /// Largest relative logit deviation from the reference per phase and
    /// greedy disagreements, with the reference's top-two margin at each.
    struct Tally: CustomStringConvertible {
        var prefill: Float = 0
        var decode: Float = 0
        var disagreements = 0
        var margins: [Float] = []

        mutating func record(_ expected: MLXArray, _ actual: MLXArray, decode: Bool) -> String {
            let scale = abs(expected).max().item(Float.self)
            let deviation = abs(actual - expected).max().item(Float.self) / max(scale, .leastNormalMagnitude)
            if decode { self.decode = max(self.decode, deviation) } else { prefill = max(prefill, deviation) }
            guard argMax(expected).item(Int32.self) != argMax(actual).item(Int32.self) else {
                return "\(deviation)"
            }
            disagreements += 1
            let top = sorted(expected)[(expected.dim(0) - 2)...]
            margins.append((top[1] - top[0]).item(Float.self))
            return "\(deviation) argmax differs (margin \(margins.last!))"
        }

        var description: String {
            "max_relative prefill \(prefill) decode \(decode) argmax_disagreements \(disagreements) "
                + "margins \(margins)"
        }
    }

    /// One storage arm over the shared installed model.
    final class Arm {
        let adapter: NemotronSuperRecurrentAdapter
        let backend: any CBv2KVBackend
        let bank: CBv2LayerCacheBank
        let lane: Lane

        init(_ model: NemotronSuperModel, paged: Bool) throws {
            adapter = NemotronSuperRecurrentAdapter(model)
            let kinds = model.cbv2LayerKinds
            if paged {
                let types = try #require(model.languageModel.observedAttentionKVDTypes())
                #expect(types.count == kinds.count && types.allSatisfy { $0 == .bfloat16 })
                let paged = try PagedKVBackend(
                    layerKinds: kinds,
                    config: .init(capacityBytes: 1 << 30, dtype: types[0], maxPrefillChunk: chunk,
                        nominalMaxSequenceLength: maximumLength,
                        maxBufferLength: MLX.GPU.deviceInfo().maxBufferSize,
                        segmentSizeBytes: 64 << 20, layerDTypes: types))
                let storage = paged.makeLayerCaches()
                let slots = Dictionary(uniqueKeysWithValues: kinds.enumerated().map {
                    ($0.element.modelLayerIndex ?? $0.offset, $0.offset)
                })
                backend = paged
                bank = CBv2LayerCacheBank(caches: try model.languageModel.newCacheV2 { index, _ in
                    guard let slot = slots[index] else { throw Failure.layout }
                    return storage[slot]
                })
            } else {
                backend = CBv2ContiguousKVBackend(config: .init(bytesCapacity: 1 << 30, kvDType: .bfloat16))
                bank = CBv2LayerCacheBank(caches: model.languageModel.newCacheV2 {
                    CBv2LayerCache(layerIndex: $0, kind: $1)
                })
            }
            lane = Lane(rows: try backend.makeSequenceState(layerKinds: kinds, promptLength: promptTokens,
                maxLength: maximumLength), state: try CBv2RecurrentRequestState(spec: model.cbv2RecurrentStateSpec))
        }

        private func caches() -> [KVCache] {
            bank.layerCaches(rowStates: [lane.rows]).map { $0 as! KVCache }
        }

        /// Float32 final-position logits of one prompt chunk.
        func prefill(_ tokens: ArraySlice<Int32>) throws -> MLXArray {
            let cache = caches()
            let binding = try lane.state.bind()
            let logits = adapter.cbv2RecurrentPrefill(MLXArray(Array(tokens)).reshaped(1, tokens.count),
                inputEmbedding: nil, cache: cache, recurrentState: [binding], positionIds: nil,
                requirement: .lastPositionLogits)
            let last = logits.reshaped(-1, logits.dim(-1))[-1].asType(.float32)
            eval([last] + (try binding.evaluate()) + cache.flatMap { $0.innerState() })
            try binding.commit()
            return last
        }

        /// Float32 logits of one decode step.
        func decode(_ token: Int32) throws -> MLXArray {
            let cache = caches()
            let binding = try lane.state.bind()
            let logits = adapter.cbv2Forward(MLXArray([token]).reshaped(1, 1), caches: cache,
                recurrentState: [binding])[0, -1].asType(.float32)
            eval([logits] + (try binding.evaluate()) + cache.flatMap { $0.innerState() })
            try binding.commit()
            return logits
        }

        func release() throws {
            bank.releaseBoundRows()
            try lane.state.release()
            backend.release(lane.rows)
        }
    }

    /// Deterministic prose of numbered records: varied tokens whose later
    /// sentences repeat earlier names, so attention spans the whole context.
    static func prose(words: Int) -> String {
        let subjects = ["The river", "A merchant", "The council", "An engineer", "The orchard", "A courier",
                        "The archive", "A lighthouse keeper", "The miller", "A cartographer"]
        let verbs = ["recorded", "measured", "delivered", "repaired", "planted", "counted", "described",
                     "inspected", "copied", "returned"]
        let objects = ["seventeen barrels", "the northern bridge", "a ledger of tides", "three copper gears",
                       "the winter harvest", "a sealed letter", "the eastern road", "forty lanterns",
                       "a map of the delta", "the old clock"]
        var state: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        var sentences: [String] = []
        var count = 0
        while count < words {
            let sentence = "Record \(sentences.count + 1): \(subjects[next(10)]) \(verbs[next(10)]) "
                + "\(objects[next(10)]) on day \(next(365) + 1), near marker \(next(9000) + 100)."
            count += sentence.split(separator: " ").count
            sentences.append(sentence)
        }
        return sentences.joined(separator: " ")
    }

    @Test(.enabled(if: enabled), .timeLimit(.minutes(20)))
    func pinnedCheckpointPagedLogitsStayWithinTolerance() async throws {
        let directory = URL(fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["NEMOTRON_SUPER_CHECKPOINT_DIR"]), isDirectory: true)
        let inputs = try NemotronSuperCheckpoint.Inputs(directory: directory)
        let files = try await NemotronSuperCheckpoint.openShards(directory: directory,
            names: inputs.inventory.shards, parallelism: 8)
        let source = try ModelOptCheckpointSource(indexData: inputs.indexData,
            indexSHA256: inputs.indexSHA256, files: files)
        let allowance = 2 << 30
        let quote = try NemotronSuperInstallation.requiredLoadBytes(source: source, backendAllowanceBytes: allowance)
        let construction = NativeConstructionScope()
        let installed = try NemotronSuperInstallation.stage(
            configuration: try NemotronSuperImageConfiguration(data: inputs.configData), source: source,
            residency: try NemotronSuperResidency(capacityBytes: quote, maximumRequests: 1),
            backendAllowanceBytes: allowance, construction: construction)
        defer { installed.closeAfterRetirement() }
        let model = try #require(installed.model)

        let tokenizer = try await LocalTokenizerLoader().load(from: directory)
        let encoded = tokenizer.encode(text: Self.prose(words: 14_000), addSpecialTokens: false)
        try #require(encoded.count >= Self.promptTokens, "prose encodes to \(encoded.count) tokens")
        let prompt = encoded.prefix(Self.promptTokens).map(Int32.init)

        // Reference and paged prefill in the production chunk; the calibration
        // arm is contiguous storage prefilled in half chunks, an equally valid
        // attention reduction, so its deviation is the trunk's own sensitivity.
        let reference = try Arm(model, paged: false)
        let paged = try Arm(model, paged: true)
        let calibration = try Arm(model, paged: false)
        var pagedTally = Tally(), calibrationTally = Tally()
        var lines: [String] = []

        var token: Int32 = 0
        var position = 0
        for start in stride(from: 0, to: prompt.count, by: Self.chunk) {
            let end = min(prompt.count, start + Self.chunk)
            position = end
            let expected = try reference.prefill(prompt[start ..< end])
            let actual = try paged.prefill(prompt[start ..< end])
            var calibrated = expected
            for half in stride(from: start, to: end, by: Self.chunk / 2) {
                calibrated = try calibration.prefill(prompt[half ..< min(end, half + Self.chunk / 2)])
            }
            token = argMax(expected).item(Int32.self)
            lines.append("prefill \(position) paged \(pagedTally.record(expected, actual, decode: false)) "
                + "calibration \(calibrationTally.record(expected, calibrated, decode: false))")
        }
        for _ in 0 ..< Self.decodeSteps {
            position += 1
            let expected = try reference.decode(token)
            let actual = try paged.decode(token)
            let calibrated = try calibration.decode(token)
            token = argMax(expected).item(Int32.self)
            lines.append("decode \(position) paged \(pagedTally.record(expected, actual, decode: true)) "
                + "calibration \(calibrationTally.record(expected, calibrated, decode: true))")
        }
        for line in lines { print("SUPER_PAGED_LIVE \(line)") }
        print("SUPER_PAGED_LIVE prompt \(prompt.count) chunk \(Self.chunk) decode \(Self.decodeSteps) "
            + "paged \(pagedTally) calibration(chunk \(Self.chunk / 2)) \(calibrationTally)")
        // Same chunk geometry: paged prefill gathers its pages into the same
        // attention, bit for bit.
        #expect(pagedTally.prefill == 0)
        // Decode reduces differently; the stated bound is the synthetic
        // tolerance or twice the calibration arm's deviation, whichever is larger.
        #expect(pagedTally.decode <= max(Self.tolerance, 2 * calibrationTally.decode))
        #expect(pagedTally.disagreements <= max(2, 2 * calibrationTally.disagreements))
        try reference.release()
        try paged.release()
        try calibration.release()
        #expect((paged.backend as? PagedKVBackend)?.bytesReserved == 0)
    }
}
