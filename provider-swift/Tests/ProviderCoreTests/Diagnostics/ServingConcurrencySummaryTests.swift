import Foundation
import ProviderCore
import Testing

@Test func servingConcurrencySummaryAutomaticDefaultIncludesModelOverrides() throws {
    let backend = try JSONDecoder().decode(BackendSettings.self, from: Data("""
        {"engine_v2_max_concurrent_by_model":{"z-model":2,"gemma-4-26b-qat-4bit":1}}
        """.utf8))
    #expect(!backend.engineV2MaxConcurrentIsExplicit)

    let summary = ServingPerformanceProfiles.summary(backend: backend)
    #expect(summary.hasPrefix("Automatic default; unknown profiles keep default 4;"))
    #expect(summary.contains("model overrides: gemma-4-26b-qat-4bit=1, z-model=2;"))
    #expect(summary.contains("higher widths require an exact reviewed model/runtime/hardware profile"))
}

@Test func servingConcurrencySummaryExplicitDefaultIncludesModelOverrides() throws {
    let backend = try JSONDecoder().decode(BackendSettings.self, from: Data("""
        {"engine_v2_max_concurrent":6,"engine_v2_max_concurrent_by_model":{"z-model":8,"a-model":1}}
        """.utf8))
    #expect(backend.engineV2MaxConcurrentIsExplicit)

    let summary = ServingPerformanceProfiles.summary(backend: backend)
    #expect(summary.hasPrefix("Default operator cap 6; unknown profiles keep cap 6;"))
    #expect(summary.contains("model overrides: a-model=1, z-model=8;"))
    #expect(!summary.contains("Automatic default"))
}

@Test func servingConcurrencySummaryDistinguishesConfiguredOverridesFromFallbackBounds() {
    let backend = BackendSettings(engineV2MaxConcurrent: 16,
        engineV2MaxConcurrentByModel: ["z/model": 0, "AlphaModel": 16])
    let summary = ServingPerformanceProfiles.summary(backend: backend)
    #expect(summary.hasPrefix("Default operator cap 16; unknown profiles keep cap 8;"))
    #expect(summary.contains("model overrides: AlphaModel=16 (unknown profile: 8), z/model=0 (unknown profile: 1);"))
}

@Test func servingConcurrencySummaryWithoutOverridesPreservesAutomaticAndExplicitDefaults() throws {
    let automatic = try JSONDecoder().decode(BackendSettings.self, from: Data("{}".utf8))
    let explicit = BackendSettings(engineV2MaxConcurrent: 4)
    let automaticSummary = ServingPerformanceProfiles.summary(backend: automatic)
    let explicitSummary = ServingPerformanceProfiles.summary(backend: explicit)
    #expect(automaticSummary.hasPrefix("Automatic default; unknown profiles keep default 4;"))
    #expect(explicitSummary.hasPrefix("Default operator cap 4; unknown profiles keep cap 4;"))
    #expect(!automaticSummary.contains("model overrides"))
    #expect(!explicitSummary.contains("model overrides"))
}
