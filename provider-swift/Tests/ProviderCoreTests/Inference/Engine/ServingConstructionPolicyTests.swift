import Testing
import MLXLMCommon
@testable import ProviderCore

@Test func servingConstructionPolicyPreservesBenchmarkWidthAndPerModelPrefill() {
    let environment = [
        MixedPrefillPolicy.modelKey: "unreviewed-mimo=256",
        EngineV2Factory.soloPrefillStripeKey: "4096",
    ]
    for backend in [EngineV2KVBackendKind.contiguous, .paged] {
        let serving = EngineV2Factory.productionServingPolicy(
            model: nil, modelID: "unreviewed-mimo", modelArtifactSHA256: nil,
            constructionPurpose: .serving, automaticallySelectConcurrency: true,
            performanceQualificationAllowed: true, backend: backend,
            maxContextLength: 8192, maxConcurrentRequests: 16, environment: environment)
        let benchmark = EngineV2Factory.productionServingPolicy(
            model: nil, modelID: "unreviewed-mimo", modelArtifactSHA256: nil,
            constructionPurpose: .benchmark, automaticallySelectConcurrency: true,
            performanceQualificationAllowed: true, backend: backend,
            maxContextLength: 8192, maxConcurrentRequests: 16, environment: environment)
        #expect(serving.performanceProfile == nil)
        #expect(benchmark.performanceProfile == nil)
        #expect(serving.scheduler.maxConcurrentRequests == 8)
        #expect(benchmark.scheduler.maxConcurrentRequests == 16)
        #expect(serving.scheduler.mixedStepPrefillTokenCap == 256)
        #expect(benchmark.scheduler.mixedStepPrefillTokenCap == 256)
        #expect(serving.scheduler.soloPrefillStripeTokens == 4096)
        #expect(benchmark.scheduler.soloPrefillStripeTokens == 4096)
    }
}

@Test func servingConstructionPolicyPreservesExplicitLowerConcurrency() {
    let policy = EngineV2Factory.productionServingPolicy(
        model: nil, modelID: "unreviewed-mimo", modelArtifactSHA256: String(repeating: "a", count: 64),
        constructionPurpose: .serving, automaticallySelectConcurrency: false,
        performanceQualificationAllowed: false, backend: .contiguous,
        maxContextLength: 8192, maxConcurrentRequests: 2, environment: [:])
    #expect(policy.performanceProfile == nil)
    #expect(policy.scheduler.maxConcurrentRequests == 2)
}
