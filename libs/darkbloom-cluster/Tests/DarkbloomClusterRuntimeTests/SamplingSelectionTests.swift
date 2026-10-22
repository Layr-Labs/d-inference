import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

// The selecting rank's sampler: the product's own `CBv2DefaultSampler`
// keyed on (seed, stream, output index). Small synthetic logits only; no
// model, collective or second process.

private let vocabulary = 64

private func samplingProfile() throws -> QwenLayerStageGenerationProfile {
    try QwenLayerStageGenerationProfile(identifier: "qwen35-sampling-fixture", vocabularySize: vocabulary,
        hiddenSize: 32, activationDType: "bfloat16", maximumPromptTokens: 128,
        maximumChunkTokens: 16, maximumOutputTokens: 32, maximumContextTokens: 256)
}

private func sampling(temperature: Float = 0.8, topP: Float = 1, topK: Int = 0, seed: UInt64 = 7,
                      stream: UInt64 = 0x8000_0000_0000_0042, repetitionPenalty: Float = 1,
                      frequencyPenalty: Float = 0, presencePenalty: Float = 0,
                      bias: [ClusterWorkerSampling.LogitBias] = []) -> ClusterWorkerSampling {
    .init(temperature: temperature, topP: topP, topK: topK, minP: 0, repetitionPenalty: repetitionPenalty,
          repetitionContextSize: 64, frequencyPenalty: frequencyPenalty, presencePenalty: presencePenalty,
          seed: seed, stream: stream, logitBias: bias)
}

private func request(_ value: ClusterWorkerSampling?, id: UUID = UUID()) throws -> QwenLayerStageGenerationRequest {
    try QwenLayerStageGenerationRequest(profile: samplingProfile(), requestID: id, promptTokenIDs: [1, 2, 3, 4],
        chunkSize: 4, outputCount: 32, stopTokenIDs: [], sampling: value)
}

/// A deterministic, fairly flat row for step `step`: every token is drawn
/// often enough that different keys give different sequences.
private func row(_ step: Int) -> [Float] {
    (0..<vocabulary).map { Float(sin(Double($0 * 7 + step * 13)) * 1.5) }
}

private func logits(_ values: [Float]) -> MLXArray {
    MLXArray(values).reshaped([1, vocabulary]).asType(.bfloat16)
}

private func select(_ request: QwenLayerStageGenerationRequest, steps: Int) throws -> [Int] {
    try (0..<steps).map { try QwenLayerStageGenerationSelection.token(logits(row($0)), request: request, check: {}) }
}

/// The product's step path rebuilt from its parts, as `CBv2DefaultSampler`
/// composes them: one pipeline + sampler configured from the row context,
/// then process, sample, commit per step.
private func productReference(_ value: ClusterWorkerSampling, prompt: [Int], steps: Int) -> [Int] {
    let params = CBv2SamplingParams(temperature: value.temperature, topP: value.topP, topK: value.topK, minP: value.minP,
        repetitionPenalty: value.repetitionPenalty, repetitionContextSize: value.repetitionContextSize,
        frequencyPenalty: value.frequencyPenalty, presencePenalty: value.presencePenalty, seed: value.seed,
        logitBias: Dictionary(uniqueKeysWithValues: value.logitBias.map { ($0.tokenID, $0.bias) }))
    let id = CBv2RequestID(value.stream)
    let pipeline = LogitsPipelineV2(vocabSize: vocabulary)
    let sampler = SamplerV2(fallbackSeed: 999)
    let rows = [CBv2SamplerRow(id: id, params: params, promptTokens: prompt)]
    pipeline.setRows(rows); sampler.setRows(rows)
    var out: [Int] = []
    for step in 0..<steps {
        let processed = pipeline.process(logits(row(step)))
        let token = sampler.sample(from: processed.sampling)
        pipeline.commit(sampledTokens: token); sampler.commit()
        eval(token)
        out.append(Int(token.reshaped([-1]).asType(.int32).item(Int32.self)))
    }
    return out
}

@Suite("Sampling on the selecting rank (synthetic logits)")
struct SamplingSelectionTests {
    @Test func greedyRequestsKeepTheirFingerprintAndSamplingIsAgreed() throws {
        let id = UUID()
        let greedy = try request(nil, id: id)
        let plain = try QwenLayerStageGenerationRequest(profile: samplingProfile(), requestID: id,
            promptTokenIDs: [1, 2, 3, 4], chunkSize: 4, outputCount: 32, stopTokenIDs: [])
        #expect(greedy.fingerprint == plain.fingerprint && greedy.sampler == nil)
        let sampled = try request(sampling(), id: id)
        #expect(sampled.fingerprint != greedy.fingerprint)
        #expect(try request(sampling(), id: id).fingerprint == sampled.fingerprint)
        #expect(try request(sampling(seed: 8), id: id).fingerprint != sampled.fingerprint)
        #expect(try request(sampling(stream: 43), id: id).fingerprint != sampled.fingerprint)
        // A no-op sampling is never built; tokens outside the profile are refused.
        #expect(throws: ProbeError.self) { _ = try request(sampling(temperature: 0)) }
        #expect(throws: ProbeError.self) { _ = try request(sampling(bias: [.init(tokenID: vocabulary, bias: 1)])) }
        #expect(throws: ProbeError.self) { _ = try request(sampling(topK: vocabulary + 1)) }
    }

    @Test func seededDrawsAreTheProductsAndReproducible() throws {
        for value in [sampling(), sampling(temperature: 1.3, topP: 0.9, topK: 20),
                      sampling(temperature: 0.6, repetitionPenalty: 1.3, frequencyPenalty: 0.4, presencePenalty: 0.2)] {
            let first = try select(request(value), steps: 24)
            let second = try select(request(value), steps: 24)
            #expect(first == second)
            #expect(first == productReference(value, prompt: [1, 2, 3, 4], steps: 24))
        }
        let a = try select(request(sampling(seed: 1)), steps: 24)
        let b = try select(request(sampling(seed: 2)), steps: 24)
        let c = try select(request(sampling(seed: 1, stream: 0x8000_0000_0000_0043)), steps: 24)
        #expect(a != b && a != c)
        // Not an argmax: a flat row at temperature 0.8 does not repeat the greedy pick.
        let greedy = try select(request(nil), steps: 24)
        #expect(a != greedy)
    }

    @Test func greedyWithLogitBiasStillAppliesTheBias() throws {
        let biased = try request(sampling(temperature: 0, bias: [.init(tokenID: 5, bias: 100)]))
        #expect(try select(biased, steps: 8) == Array(repeating: 5, count: 8))
        let banned = try request(sampling(temperature: 0, bias: [.init(tokenID: try select(request(nil), steps: 1)[0], bias: -100)]))
        #expect(try select(banned, steps: 1) != (try select(request(nil), steps: 1)))
        // top_k 1 at any temperature is the argmax.
        #expect(try select(request(sampling(temperature: 2, topK: 1)), steps: 12) == (try select(request(nil), steps: 12)))
    }

    /// Target-prefix verification: column j of a window is the draw the
    /// ordinary step path makes at output index base + j for the same row, so
    /// a speculative round commits exactly the plain path's tokens.
    @Test func verifyColumnsAreTheOrdinaryDrawsAtTheirOutputIndex() throws {
        let value = sampling(temperature: 0.9, topP: 0.95)
        let sequential = try request(value)
        let prefix = try select(sequential, steps: 3)
        let plain = try (3..<8).map { try QwenLayerStageGenerationSelection.token(logits(row($0)), request: sequential, check: {}) }
        let speculative = try request(value)
        #expect(try select(speculative, steps: 3) == prefix)
        let window = MLXArray((3..<8).flatMap { row($0) }).reshaped([1, 5, vocabulary]).asType(.bfloat16)
        let verify = try #require(speculative.sampler?.verify(window))
        eval(verify)
        let columns = verify.reshaped([-1]).asType(.int32).asArray(Int32.self).map(Int.init)
        #expect(columns == plain)
        speculative.sampler?.commitRound(columns)
        // After a round the step path continues at the next output index.
        let next = try QwenLayerStageGenerationSelection.token(logits(row(8)), request: speculative, check: {})
        let nextPlain = try QwenLayerStageGenerationSelection.token(logits(row(8)), request: sequential, check: {})
        #expect(next == nextPlain && speculative.sampler?.nextOutputIndex == 9)
        // History-dependent transforms are never verified speculatively.
        let penalised = try request(sampling(repetitionPenalty: 1.2))
        #expect(penalised.sampler?.verify(window) == nil)
        #expect(try request(sampling(temperature: 0, bias: [.init(tokenID: 1, bias: 1)])).sampler?.admitsSpeculativeVerification == false)
    }
}
