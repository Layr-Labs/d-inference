import DarkbloomClusterProtocol
import Foundation
import MLX
import Testing
@testable import DarkbloomClusterRuntime

/// The pipeline's actual decode selector, with CPU logits only. Requests are
/// independent of a model, native worker, collective, or resident KV state.
@Suite("Qwen batch selection (CPU synthetic logits)")
struct QwenBatchSelectionTests {
    private let vocabulary = 64

    private func request(_ sampling: ClusterWorkerSampling?, vocabulary: Int = 64,
                         dtype: String = "bfloat16") throws -> QwenLayerStageGenerationRequest {
        let profile = try QwenLayerStageGenerationProfile(identifier: "qwen-batch-selection-fixture",
            vocabularySize: vocabulary, hiddenSize: 32, activationDType: dtype,
            maximumPromptTokens: 128, maximumChunkTokens: 16,
            maximumOutputTokens: 32, maximumContextTokens: 256)
        return try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
            promptTokenIDs: [1, 2, 3, 4], chunkSize: 4, outputCount: 32, stopTokenIDs: [], sampling: sampling)
    }

    private func sampling(temperature: Float = 0.8, topP: Float = 1, topK: Int = 0,
                          seed: UInt64 = 7, stream: UInt64 = 42, repetition: Float = 1,
                          frequency: Float = 0, presence: Float = 0,
                          bias: [ClusterWorkerSampling.LogitBias] = []) -> ClusterWorkerSampling {
        .init(temperature: temperature, topP: topP, topK: topK, minP: 0,
            repetitionPenalty: repetition, repetitionContextSize: 64,
            frequencyPenalty: frequency, presencePenalty: presence,
            seed: seed, stream: stream, logitBias: bias)
    }

    private func values(lane: Int, step: Int) -> [Float] {
        (0..<vocabulary).map { Float(sin(Double($0 * 7 + step * 13 + lane * 5)) * 1.5) }
    }

    private func matrix(_ rows: [[Float]], dtype: DType = .bfloat16) -> MLXArray {
        MLXArray(rows.flatMap { $0 }).reshaped([rows.count, rows[0].count]).asType(dtype)
    }

    private func batch(_ rows: [[Float]], _ requests: [QwenLayerStageGenerationRequest]) throws -> [Int] {
        try QwenResidentRuntime.selectBatchTokens(matrix(rows), requests: requests, check: {})
    }

    private func alone(_ row: [Float], _ request: QwenLayerStageGenerationRequest) throws -> Int {
        try QwenLayerStageGenerationSelection.token(matrix([row]), request: request, check: {})
    }

    @Test func zeroTemperatureBiasBelongsToEachRowIncludingAfterAGreedyRow() throws {
        try Device.withDefaultDevice(.cpu) {
            var row = [Float](repeating: -1, count: vocabulary)
            row[3] = 4
            let requests = try [request(nil),
                request(sampling(temperature: 0, bias: [.init(tokenID: 5, bias: 100)])),
                request(sampling(temperature: 0, bias: [.init(tokenID: 9, bias: 100)]))]
            for _ in 0..<4 {
                #expect(try batch([row, row, row], requests) == [3, 5, 9])
            }
        }
    }

    @Test func mixedLanesKeepTheirOwnSeedAndPenaltyHistoryAcrossDecodeSteps() throws {
        try Device.withDefaultDevice(.cpu) {
            let settings: [ClusterWorkerSampling?] = [nil, sampling(seed: 1),
                sampling(temperature: 1.2, topP: 0.9, topK: 20, seed: 2, stream: 43),
                sampling(temperature: 0.7, seed: 3, stream: 44, repetition: 1.4, frequency: 0.5, presence: 0.3),
                sampling(temperature: 0, stream: 45, bias: [.init(tokenID: 5, bias: 100)])]
            let batched = try settings.map { try request($0) }
            let references = try settings.map { try request($0) }
            let raw = try settings.map { _ in try request(nil) }
            // The final prefill token uses scalar selection before the runtime
            // enters batched decode; its history must carry into every row.
            for lane in settings.indices {
                let prefill = values(lane: lane, step: -1)
                #expect(try alone(prefill, batched[lane]) == alone(prefill, references[lane]))
            }
            var differsFromArgmax = false
            for step in 0..<24 {
                let rows = settings.indices.map { values(lane: $0, step: step) }
                let actual = try batch(rows, batched)
                let expected = try settings.indices.map { try alone(rows[$0], references[$0]) }
                let greedy = try settings.indices.map { try alone(rows[$0], raw[$0]) }
                #expect(actual == expected, "decode step \(step)")
                differsFromArgmax = differsFromArgmax || actual != greedy
            }
            #expect(differsFromArgmax)
        }
    }

    @Test func rowReorderingAndChangingActiveLanesDoNotAdvanceOtherSamplers() throws {
        try Device.withDefaultDevice(.cpu) {
            let settings = (0..<4).map { lane in
                sampling(temperature: 0.8, seed: UInt64(lane + 1), stream: UInt64(lane + 42),
                    repetition: 1.3, frequency: 0.4)
            }
            let batched = try settings.map { try request($0) }
            let references = try settings.map { try request($0) }
            let schedule = [[0], [2, 0], [3, 1, 0, 2], [2, 1], [3], [1, 3, 2, 0]]
            var steps = [Int](repeating: 0, count: settings.count)
            for tick in 0..<24 {
                let active = schedule[tick % schedule.count]
                let rows = active.map { values(lane: $0, step: steps[$0]) }
                let actual = try batch(rows, active.map { batched[$0] })
                let expected = try active.enumerated().map { try alone(rows[$0.offset], references[$0.element]) }
                #expect(actual == expected, "active lanes \(active)")
                for lane in active { steps[lane] += 1 }
            }
        }
    }

    @Test(arguments: [1, 2, 4, 8])
    func plainGreedyBatchesKeepTheExistingVectorizedArgmax(lanes: Int) throws {
        try Device.withDefaultDevice(.cpu) {
            let requests = try (0..<lanes).map { _ in try request(nil) }
            let rows = (0..<lanes).map { lane -> [Float] in
                var row = values(lane: lane, step: 3)
                row[7] = 4; row[11] = 4 // Preserve first-index tie selection.
                return row
            }
            let logits = matrix(rows)
            let original = argMax(logits, axis: -1), finite = all(isFinite(logits), axes: [-1])
            eval(logits, original, finite)
            #expect(finite.asArray(Bool.self).allSatisfy { $0 })
            let expected = original.asArray(UInt32.self).map(Int.init)
            #expect(try QwenResidentRuntime.selectBatchTokens(logits, requests: requests, check: {}) == expected)
            #expect(expected == [Int](repeating: 7, count: lanes))
        }
    }

    @Test func anInvalidLaterRowDoesNotCommitAnEarlierSampler() throws {
        try Device.withDefaultDevice(.cpu) {
            for invalid in [Float.nan, .infinity, -.infinity] {
                let settings = [sampling(seed: 3, repetition: 1.5, frequency: 0.5), sampling(seed: 4, stream: 43)]
                let batched = try settings.map { try request($0) }
                let references = try settings.map { try request($0) }
                var rows = [values(lane: 0, step: 0), values(lane: 1, step: 0)]
                rows[1][7] = invalid
                #expect(throws: ProbeError.self) { try batch(rows, batched) }
                for step in 0..<8 {
                    let valid = settings.indices.map { values(lane: $0, step: step) }
                    #expect(try batch(valid, batched) == settings.indices.map { try alone(valid[$0], references[$0]) })
                }
            }
        }
    }

    @Test func shapeAndProfileRefusalsLeaveSamplersUnchanged() throws {
        try Device.withDefaultDevice(.cpu) {
            let setting = sampling(seed: 9, repetition: 1.4, frequency: 0.5)
            let sampled = try request(setting), reference = try request(setting)
            let row = values(lane: 0, step: 0)
            #expect(throws: ProbeError.self) {
                try QwenResidentRuntime.selectBatchTokens(matrix([row]), requests: [], check: {})
            }
            #expect(throws: ProbeError.self) { try batch([row, row], [sampled]) }
            #expect(throws: ProbeError.self) {
                try QwenResidentRuntime.selectBatchTokens(matrix([row], dtype: .float32), requests: [sampled], check: {})
            }
            #expect(throws: ProbeError.self) { try batch([row, row], [sampled, request(nil, vocabulary: 32)]) }
            #expect(throws: ProbeError.self) { try batch([row, row], [sampled, request(nil, dtype: "float32")]) }
            for step in 0..<8 {
                let valid = values(lane: 0, step: step)
                #expect(try batch([valid], [sampled]) == [alone(valid, reference)])
            }
        }
    }
}
