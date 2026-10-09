import ProviderCore
import Testing

@testable import ProviderBenchmark

@Suite("scheduler-prefill KV precision construction inputs")
struct SchedulerPrefillDecisionKVProvenanceTests {
    private let modelID = "qwen3.6-35b-a3b-vl-mtp-mxfp8"

    @Test("the default snapshot supplies balanced precision to construction")
    func defaultProjection() throws {
        let resolved = try SchedulerPrefillDecisionKVProvenance.environment(
            modelType: "qwen3_5_moe", modelID: modelID,
            global: "balanced", byModel: [:], environment: [:])
        #expect(resolved[EngineV2KVQuantizationPolicy.environmentKey] == "balanced")
    }

    @Test("configuration and per-model precision reach construction without changing other inputs")
    func configurationProjection() throws {
        let environment = ["OTHER_RUNTIME_INPUT": "preserved"]
        let global = try SchedulerPrefillDecisionKVProvenance.environment(
            modelType: "qwen3_5_moe", modelID: modelID,
            global: "k8v8", byModel: [:], environment: environment)
        #expect(global[EngineV2KVQuantizationPolicy.environmentKey] == "k8v8")
        #expect(global["OTHER_RUNTIME_INPUT"] == "preserved")
        let perModel = try SchedulerPrefillDecisionKVProvenance.environment(
            modelType: "qwen3_5_moe", modelID: modelID,
            global: "balanced", byModel: [modelID: "off", "another-model": "k8v4"],
            environment: environment)
        #expect(perModel[EngineV2KVQuantizationPolicy.environmentKey] == "native")
        #expect(environment[EngineV2KVQuantizationPolicy.environmentKey] == nil)
    }

    @Test("explicit environment and CLI aliases override the runtime snapshot")
    func environmentOverride() throws {
        let resolved = try SchedulerPrefillDecisionKVProvenance.environment(
            modelType: "qwen3_5_moe", modelID: modelID,
            global: "native", byModel: [modelID: "k8v8"],
            environment: [EngineV2KVQuantizationPolicy.environmentKey: "int4"])
        #expect(resolved[EngineV2KVQuantizationPolicy.environmentKey] == "balanced")
    }

    @Test("MiMo remains native before any global, model or explicit override is parsed")
    func mimoExemption() throws {
        let resolved = try SchedulerPrefillDecisionKVProvenance.environment(
            modelType: "mimo_v2", modelID: "mimo-v2.6",
            global: "invalid", byModel: ["mimo-v2.6": "k8v8"],
            environment: [EngineV2KVQuantizationPolicy.environmentKey: "invalid"])
        #expect(resolved[EngineV2KVQuantizationPolicy.environmentKey] == "native")
    }

    @Test("malformed effective non-MiMo selection is refused before loading")
    func invalidProjection() {
        #expect(throws: EngineV2KVQuantizationPolicy.Failure.self) {
            _ = try SchedulerPrefillDecisionKVProvenance.environment(
                modelType: "qwen3_5_moe", modelID: modelID,
                global: "balanced", byModel: [modelID: "unqualified"],
                environment: [:])
        }
    }
}
