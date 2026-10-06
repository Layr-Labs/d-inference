import MLXVLM
import Testing
@testable import ProviderCore

@Test func mimoMediaMemoryRefusalHasItsOwnBoundedReason() throws {
    let error = MiMoV26EncodedMediaIngress.outwardFailure(MiMoV26MultimodalError.reservationRejected)
    #expect(error as? MultiModelBatchSchedulerEngineError == .mediaMemoryUnavailable)
    let failure = ProviderLoop.sanitizedInferenceFailure(from: error, phase: .streamStart)
    #expect(failure.code == .capacity)
    #expect(failure.statusCode == 503)
    #expect(failure.errorReason == .mediaMemoryUnavailable)
    #expect(failure.terminalCause == nil)
    let wire = try ProviderProtocolCodec.encodeProviderMessage(.inferenceError(.init(requestId: "media-test", failure: failure)))
    #expect(String(decoding: wire, as: UTF8.self).contains("media_memory_unavailable"))
}

@Test func mimoVisionQuotaRefusalsDoNotBecomeEngineFaults() {
    let inputs: [any Error] = [
        MiMoV26VisionError.executionLimit("PRIVATE_DIMENSION"),
        MiMoV26Pixels.Failure.resourceLimit("PRIVATE_DIMENSION"),
    ]
    for input in inputs {
        let failure = ProviderLoop.sanitizedInferenceFailure(
            from: MiMoV26EncodedMediaIngress.outwardFailure(input), phase: .streamStart)
        #expect(failure.errorReason == .mediaMemoryUnavailable)
        #expect(failure.statusCode == 503)
        #expect(!failure.message.contains("PRIVATE_DIMENSION"))
    }
}

@Test func mimoMediaMemoryRefusalDoesNotPublishAFalseTextBudgetVerdict() {
    let failure = InferenceFailure(code: .capacity, statusCode: 503, errorReason: .mediaMemoryUnavailable)
    let enriched = CapacityRejectionEnrichment.enrich(
        failure, modelId: "mimo-v2.6-flash-mopd", published: nil,
        fallbackReason: .tokenBudget, neededTokens: 131072)
    #expect(enriched == failure)
    #expect(CapacityRejectionReason(errorReason: .mediaMemoryUnavailable) == nil)
}

@Test func mimoMediaRefusalClassificationPreservesRealNativeFailures() {
    let error = MiMoV26EncodedMediaIngress.outwardFailure(MiMoV26MultimodalError.drainFailed)
    #expect(error as? MiMoV26MultimodalError == .drainFailed)
    let failure = ProviderLoop.sanitizedInferenceFailure(from: error, phase: .generation)
    #expect(failure.errorReason != .mediaMemoryUnavailable)
    #expect(failure.statusCode == 500)
}
