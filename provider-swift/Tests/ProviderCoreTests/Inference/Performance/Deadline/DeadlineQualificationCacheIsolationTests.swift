import Foundation
import MLXLLM
import MLXLMCommon
import Testing
@testable import ProviderCore

private func fixtureEnvironment(_ root: URL) -> [String: String] {
    ["DARKBLOOM_PREFIX_CACHE_TEST_ROOT": root.path, "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1"]
}

@Test func deadlineQualificationCacheIsolationRequiresExactOwnedSafePair() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let isolation = try DeadlineQualificationCacheIsolation(cacheRoot: root)
    let environment = fixtureEnvironment(root)
    #expect(!DeadlineRuntimeEnvironment.permitsQualification(environment))
    #expect(DeadlineRuntimeEnvironment.permitsQualification(environment, cacheIsolation: isolation))
    for changed in [[:], ["DARKBLOOM_PREFIX_CACHE_TEST_ROOT": root.path],
                    ["DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1"],
                    fixtureEnvironment(root.appendingPathComponent("other")),
                    environment.merging(["DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "true"]) { _, b in b }] {
        #expect(!DeadlineRuntimeEnvironment.permitsQualification(changed, cacheIsolation: isolation))
    }
    for key in ["MLX_FUTURE_TUNING", "MTPLX_FUTURE_TUNING", "QWEN_FUTURE_TUNING",
                "DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY", "DARKBLOOM_PREFIX_CACHE",
                "DARKBLOOM_CBV2_MIXED_PREFILL_CAP", "DARKBLOOM_UNKNOWN"] {
        #expect(!DeadlineRuntimeEnvironment.permitsQualification(
            environment.merging([key: "1"]) { _, b in b }, cacheIsolation: isolation))
    }
    let normal = SSDPrefixCacheFactory.cacheRootDirectory(environment: [:])
    let legacy = normal.deletingLastPathComponent().appendingPathComponent("kv")
    for unsafe in [normal, normal.appendingPathComponent("child"), normal.deletingLastPathComponent(), legacy,
                   URL(fileURLWithPath: "/"), URL(string: "https://example.invalid/cache")!] {
        #expect(throws: (any Error).self) { try DeadlineQualificationCacheIsolation(cacheRoot: unsafe) }
    }
    // Resolving an alias into the installed cache may never turn it into an isolated namespace.
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: normal)
    #expect(throws: (any Error).self) {
        try DeadlineQualificationCacheIsolation(cacheRoot: alias.appendingPathComponent("child"))
    }
}

private struct QualificationCacheProcessor: UserInputProcessor {
    struct Unused: Error {}
    func prepare(input: UserInput) async throws -> LMInput { throw Unused() }
}

// CI's virtual Mac can report zero GPU cores. The profile and this injected
// identity are synthetic; the factory still builds the real tiny engine.
private let qualificationHardware = HardwareInfo(machineModel: "test", chipName: "Apple M5 Max",
    chipFamily: .m5, chipTier: .max, memoryGb: 128, memoryAvailableGb: 100,
    cpuCores: .init(total: 16, performance: 12, efficiency: 4), gpuCores: 40, memoryBandwidthGbs: 0)

private func qualificationCacheBundle(environment: [String: String],
    isolation: DeadlineQualificationCacheIsolation?, profiles: [DeadlinePerformanceProfile]) async throws -> ProviderEngineBundle {
    let config = try JSONDecoder().decode(GPTOSSConfiguration.self, from: Data("""
        {"model_type":"gpt_oss","num_hidden_layers":2,"num_local_experts":4,
         "num_experts_per_tok":2,"vocab_size":128,"rms_norm_eps":0.00001,"hidden_size":64,
         "intermediate_size":64,"head_dim":64,"num_attention_heads":4,"num_key_value_heads":2,"sliding_window":32}
        """.utf8))
    let model = GPTOSSModel(config), tokenizer = StubBridgeTokenizer()
    let container = ModelContainer(context: ModelContext(configuration: ModelConfiguration(id: "model"),
        model: model, processor: QualificationCacheProcessor(), tokenizer: tokenizer))
    let prepared = EngineV2PreparedModel(snapshot: .init(model: model, eosTokenIds: [1], extraEOSTokens: []),
        servingModel: model, assistant: nil, mtpStatus: .disabled(.configDisabled, configured: false), mtpArtifact: nil)
    return try await EngineV2SlotFactory.makeProductionBundle(modelId: "model", modelType: "gpt_oss",
        isVLM: false, modelDirectory: nil, container: container, tokenizer: TokenizerHandle(tokenizer),
        sizing: .init(weightsBytes: 1, fp16KVBytesPerToken: 1_024, maxContextLength: 32_768, defaultMaxTokens: 32),
        kvBytesCapacity: 8 << 20, maxConcurrentRequests: 4, kvBudget: nil, kvBackendConfig: "contiguous",
        modelArtifactSHA256: String(repeating: "a", count: 64),
        specDecPreparation: .init(artifact: nil, status: .disabled(.configDisabled, configured: false)),
        preparedModel: prepared, assemblyOverrides: .init(deadlineProfiles: profiles, deadlineHardware: qualificationHardware),
        environment: environment, deadlineQualificationCacheIsolation: isolation, startServingTelemetry: false)
}

@Test func supervisedCacheIsolationResolvesOnlyMatchingProfileThroughProductionFactory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let isolation = try DeadlineQualificationCacheIsolation(cacheRoot: root)
    let environment = fixtureEnvironment(root)
    let baseline = try await qualificationCacheBundle(environment: environment, isolation: isolation, profiles: [])
    let runtime = try #require(baseline.bridge.deadlineRuntimeConfiguration)
    await baseline.bridge.shutdown()
    let hardware = qualificationHardware
    var profile = deadlineCalibrationProfileFixture()
    profile.providerVersion = ProviderCore.version
    profile.kvBackend = "contiguous"
    profile.chipName = hardware.chipName; profile.gpuCores = hardware.gpuCores; profile.memoryGb = hardware.memoryGb
    profile.effectiveMaxConcurrency = runtime.effectiveMaxConcurrency
    profile.prefillChunkSize = runtime.prefillChunkSize
    profile.maxConcurrentPartialPrefills = runtime.maxConcurrentPartialPrefills
    profile.mixedPrefillTokenCap = runtime.mixedPrefillTokenCap
    profile.soloPrefillStripeTokens = runtime.soloPrefillStripeTokens
    #expect(profile.isValid && profile.runtimeConfiguration == runtime)
    let qualified = try await qualificationCacheBundle(environment: environment, isolation: isolation, profiles: [profile])
    #expect(qualified.bridge.deadlineProfile == profile)
    #expect(qualified.bridge.deadlineRuntimeConfiguration == runtime)
    await qualified.bridge.shutdown()

    let ordinary = try await qualificationCacheBundle(environment: environment, isolation: nil, profiles: [profile])
    #expect(ordinary.bridge.deadlineProfile == nil)
    await ordinary.bridge.shutdown()
    for key in ["MLX_FUTURE_TUNING", "MTPLX_FUTURE_TUNING", "QWEN_FUTURE_TUNING"] {
        let overridden = try await qualificationCacheBundle(
            environment: environment.merging([key: "1"]) { _, b in b }, isolation: isolation, profiles: [profile])
        #expect(overridden.bridge.deadlineProfile == nil)
        await overridden.bridge.shutdown()
    }
    var different = profile
    different.artifactSha256 = String(repeating: "f", count: 64)
    let mismatched = try await qualificationCacheBundle(environment: environment, isolation: isolation, profiles: [different])
    #expect(mismatched.bridge.deadlineProfile == nil)
    await mismatched.bridge.shutdown()
    await #expect(throws: (any Error).self) {
        try await qualificationCacheBundle(environment: fixtureEnvironment(root.appendingPathComponent("wrong")),
            isolation: isolation, profiles: [profile])
    }
}
