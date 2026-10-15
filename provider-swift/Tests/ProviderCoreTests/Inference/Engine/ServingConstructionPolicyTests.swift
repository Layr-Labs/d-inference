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

@Test func servingConstructionPolicyWidensAutomaticPagedSlotsOnM5ProMaxAndUltra() {
    func width(_ chip: (family: ChipFamily, tier: ChipTier)?, modelID: String = "gemma-4-26b-qat-4bit",
        backend: EngineV2KVBackendKind = .paged, automatic: Bool = true,
        purpose: EngineV2Factory.ConstructionPurpose = .serving) -> Int {
        EngineV2Factory.productionServingPolicy(
            model: nil, modelID: modelID, modelArtifactSHA256: nil,
            constructionPurpose: purpose, automaticallySelectConcurrency: automatic,
            performanceQualificationAllowed: true, backend: backend,
            maxContextLength: 8192, maxConcurrentRequests: 4, environment: [:],
            chipIdentity: chip).scheduler.maxConcurrentRequests
    }
    #expect(width((.m5, .ultra)) == 8)
    #expect(width((.m5, .max)) == 8)
    #expect(width((.m5, .pro)) == 8)
    #expect(width((.m5, .ultra), modelID: "gpt-oss-20b") == 8)
    // The default stays 4 off paged, for a model only forced onto paged, below
    // M5 Pro, on earlier or undetected chips, for an explicit operator value
    // and for benchmark construction.
    #expect(width((.m5, .ultra), backend: .contiguous) == 4)
    #expect(width((.m5, .ultra), modelID: "unreviewed-mimo") == 4)
    #expect(width((.m5, .base)) == 4)
    #expect(width((.m4, .max)) == 4)
    #expect(width((.m3, .ultra)) == 4)
    #expect(width(nil) == 4)
    #expect(width((.m5, .ultra), automatic: false) == 4)
    #expect(width((.m5, .ultra), purpose: .benchmark) == 4)
}

@Test func servingChipIdentityMatchesTheHostBrandString() throws {
    let brand = try sysctlString("machdep.cpu.brand_string")
    let identity = try #require(EngineV2Factory.servingChipIdentity)
    let parsed = parseChipIdentity(brand)
    #expect(identity.family == parsed.0 && identity.tier == parsed.1)
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
