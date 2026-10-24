import Foundation
import Testing

@_spi(Benchmarking) @testable import ProviderCore

@Suite("Checkpoint storage qualification controls")
struct ModelCheckpointStorageSpecificationTests {
    private func benchmark() -> ModelPrefixBenchmarkSpecification {
        ModelPrefixBenchmarkSpecification(modelID: "fixture", openRouterID: "fixture/model",
            directory: "/tmp/public-fixture", expectedWeightHash: String(repeating: "a", count: 64),
            modelType: "qwen3", outputPath: "/tmp/public-fixture-report.json", pairs: 1, outputTokens: 64,
            cases: [.init(name: "short", donorTokens: 1_793, sharedTokens: 1_152,
                          forkTokens: 2_304, demandedTokens: 1_024)])
    }

    @Test("legacy JSON keeps exact native live and checkpoint controls")
    func legacyDefaults() throws {
        let original = benchmark()
        let decoded = try JSONDecoder().decode(ModelPrefixBenchmarkSpecification.self,
            from: JSONEncoder().encode(original))
        try decoded.validate()
        #expect(decoded.liveKVQuantization == nil && decoded.checkpointQuantization == nil)
        #expect(decoded.resolvedLiveKVQuantization == "native")
        #expect(decoded.resolvedCheckpointQuantization == "native")
        #expect(decoded.resolvedKVBackend == "auto")
    }

    @Test("independent profile and fixed-work counters survive JSON roundtrip")
    func independentPrecisionRoundtrip() throws {
        var configured = benchmark()
        configured.liveKVQuantization = "native"
        configured.checkpointQuantization = "balanced"
        configured.kvBackend = "contiguous"
        configured.warmupIterations = 2
        let decoded = try JSONDecoder().decode(ModelPrefixBenchmarkSpecification.self,
            from: JSONEncoder().encode(configured))
        try decoded.validate()
        #expect(decoded.resolvedLiveKVQuantization == "native")
        #expect(decoded.resolvedCheckpointQuantization == "balanced")
        #expect(decoded.resolvedKVBackend == "contiguous")
        #expect(decoded.warmupIterations == 2 && decoded.outputTokens == 64 && decoded.pairs == 1)
    }

    @Test("unknown precision and unbounded warmup are rejected before a model load")
    func invalidControls() {
        var invalid = benchmark()
        invalid.checkpointQuantization = "silent-native-fallback"
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid.checkpointQuantization = nil
        invalid.liveKVQuantization = "fp8"
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid.liveKVQuantization = nil
        invalid.kvBackend = "automatic-ish"
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid.kvBackend = nil
        invalid.warmupIterations = -1
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid.warmupIterations = 6
        #expect(throws: (any Error).self) { try invalid.validate() }
    }

    @Test("fixture environment cannot inherit ambient precision or scheduler overrides")
    func cleanFixtureEnvironment() {
        let environment = ModelPrefixBenchmarkFixture.checkpointEnvironment(
            root: URL(fileURLWithPath: "/tmp/owned-prefix-root"), soloPrefillStripeTokens: nil)
        #expect(Set(environment.keys) == Set(["DARKBLOOM_PREFIX_CACHE", "DARKBLOOM_PREFIX_CACHE_MEMORY",
            "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL", "DARKBLOOM_PREFIX_CACHE_TEST_ROOT"]))
        #expect(environment[EngineV2KVQuantizationPolicy.environmentKey] == nil)
        #expect(environment[EngineV2KVQuantizationPolicy.checkpointEnvironmentKey] == nil)
        // Precision travels through explicit factory args, not extra CBV2 env
        // flags that can accidentally alter native scheduler qualification.
        let stripe = ModelPrefixBenchmarkFixture.checkpointEnvironment(
            root: URL(fileURLWithPath: "/tmp/owned-prefix-root"), soloPrefillStripeTokens: 2_048)
        #expect(stripe[EngineV2Factory.soloPrefillStripeKey] == "2048")
        #expect(stripe[EngineV2Factory.prefillChunkKey] == "512")
        #expect(stripe[EngineV2Factory.stepTokenBudgetKey] == "2048")
    }

    @Test("performance runs do not silently enable expensive logprob diagnostics")
    func diagnosticRunsAreSeparate() throws {
        var model = benchmark()
        model.captureTokenDiagnostics = true
        let run = ModelCheckpointStorageSpecification(benchmark: model, runID: UUID(), phase: .benchmark)
        #expect(throws: ModelCheckpointStorageSpecification.Failure.diagnosticsInPerformanceRun) {
            try run.validate()
        }
    }

    @Test("duplicate case names cannot reuse a tenant scope or manufacture paired rows")
    func duplicateCases() throws {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(benchmark()))
            as? [String: Any])
        let cases = try #require(json["cases"] as? [[String: Any]])
        json["cases"] = cases + cases
        let model = try JSONDecoder().decode(ModelPrefixBenchmarkSpecification.self,
            from: JSONSerialization.data(withJSONObject: json))
        let run = ModelCheckpointStorageSpecification(benchmark: model, runID: UUID(), phase: .benchmark)
        #expect(throws: ModelCheckpointStorageSpecification.Failure.ambiguousCaseNames) { try run.validate() }
    }

    @Test("persistent phases require all isolated selectors and preserve producer reports")
    func persistentSelectors() throws {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("storage-spec-\(UUID().uuidString)")
        var run = ModelCheckpointStorageSpecification(benchmark: benchmark(), runID: UUID(), phase: .donate)
        #expect(throws: (any Error).self) { try run.validate() }
        run.checkpointRoot = temporary.path
        run.keyNamespaceID = UUID()
        #expect(throws: (any Error).self) { try run.validate() }
        run.keyAccessGroup = "TESTTEAM.io.darkbloom.qualification"
        try run.validate() // Pure path/namespace validation, no keychain or model IO.
        #expect(try run.namespace?.identifier == run.keyNamespaceID)
        #expect(!FileManager.default.fileExists(atPath: temporary.path))

        let restore = ModelCheckpointStorageSpecification(benchmark: benchmark(), runID: run.runID,
            phase: .restore, checkpointRoot: temporary.path, keyNamespaceID: run.keyNamespaceID,
            keyAccessGroup: run.keyAccessGroup, producerReportPath: benchmark().outputPath)
        #expect(throws: (any Error).self) { try restore.validate() }
        run.checkpointRoot = "/"
        #expect(throws: (any Error).self) { try run.validate() }
    }

    @Test("ephemeral benchmark cannot accidentally address persistent provider keys")
    func ephemeralRejectsPersistentSelectors() {
        var run = ModelCheckpointStorageSpecification(benchmark: benchmark(), runID: UUID(), phase: .benchmark)
        run.keyAccessGroup = "TESTTEAM.io.darkbloom.qualification"
        #expect(throws: (any Error).self) { try run.validate() }
    }

    @Test("serialized reports distinguish requested precision from effective layout")
    func precisionReportFields() throws {
        var report = ModelPrefixBenchmarkReport(modelID: "fixture", openRouterID: "fixture/model",
            weightHash: "verified", modelType: "mimo_v2", servingModelType: "NativeFixture",
            backend: "contiguous", backendFallback: nil, cacheMode: "ssd_complete", keyMode: "ephemeral",
            mtpEnabled: false, checkpointPartition: "production", strictFsync: false,
            productionKVGrantBytes: 1_024, physicalMemoryBytes: 4_096, activationReserveBytes: 512,
            outputTokens: 64, comparison: "schema-only; not execution evidence")
        report.requestedLiveKVQuantization = "native"
        report.requestedCheckpointQuantization = "balanced"
        report.liveKVQuantization = "native"
        report.checkpointQuantization = "native"
        report.checkpointBackendLayout = "native-contiguous-asymmetric-attention-v1"
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        #expect(object["requestedCheckpointQuantization"] as? String == "balanced")
        #expect(object["checkpointQuantization"] as? String == "native")
        #expect(object["liveKVQuantization"] as? String == "native")
        #expect(object["checkpointBackendLayout"] as? String == report.checkpointBackendLayout)
    }
}
