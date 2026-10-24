import Foundation
import Testing

@testable import ProviderCore

@Suite("Independent live and checkpoint KV precision config")
struct KVQuantizationConfigTests {
    @Test func nativeLiveAndBalancedCheckpointDefaultsAgree() throws {
        let defaults = BackendSettings()
        let decoded = try JSONDecoder().decode(BackendSettings.self, from: Data("{}".utf8))
        for backend in [defaults, decoded, ConfigManager.parse("").backend,
                        ConfigManager.parse("[backend]\nport = 8100").backend] {
            #expect(backend.engineV2KVQuantization == "native")
            #expect(backend.engineV2KVQuantizationByModel.isEmpty)
            #expect(backend.engineV2KVCheckpointQuantization == "balanced")
            #expect(backend.engineV2KVCheckpointQuantizationByModel.isEmpty)
        }
        let standalone = StandaloneServerConfig()
        #expect(standalone.engineV2KVQuantization == defaults.engineV2KVQuantization)
        #expect(standalone.engineV2KVQuantizationByModel.isEmpty)
        #expect(standalone.engineV2KVCheckpointQuantization == defaults.engineV2KVCheckpointQuantization)
        #expect(standalone.engineV2KVCheckpointQuantizationByModel.isEmpty)
    }

    @Test(arguments: ["native", "balanced", "k8v4", "k8v8"])
    func jsonAndTOMLRoundTripIndependentSelections(precision: String) throws {
        let backend = BackendSettings(
            engineV2KVQuantization: precision,
            engineV2KVQuantizationByModel: ["live-model": "k8v8"],
            engineV2KVCheckpointQuantization: precision,
            engineV2KVCheckpointQuantizationByModel: ["checkpoint-model": "native"])
        let data = try JSONEncoder().encode(backend)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["engine_v2_kv_quantization"] as? String == precision)
        #expect(object["engine_v2_kv_checkpoint_quantization"] as? String == precision)
        #expect(object["engine_v2_kv_checkpoint_quantization_by_model"] as? [String: String]
            == ["checkpoint-model": "native"])
        #expect(try JSONDecoder().decode(BackendSettings.self, from: data) == backend)

        let config = ProviderConfig(provider: .init(name: "precision-test"), backend: backend)
        let toml = ConfigManager.serialize(config)
        #expect(toml.contains("engine_v2_kv_checkpoint_quantization"))
        #expect(toml.contains("engine_v2_kv_checkpoint_quantization_by_model"))
        #expect(ConfigManager.parse(toml) == config)
    }

    @Test func separateTOMLTablesAndStandaloneOverridesStayIndependent() {
        let backend = ConfigManager.parse("""
            [backend]
            engine_v2_kv_quantization = "k8v4"
            engine_v2_kv_checkpoint_quantization = "native"

            [backend.engine_v2_kv_quantization_by_model]
            "model-a" = "balanced"

            [backend.engine_v2_kv_checkpoint_quantization_by_model]
            "model-a" = "k8v8"
            "model-b" = "balanced"
            """).backend
        #expect(backend.engineV2KVQuantization == "k8v4")
        #expect(backend.engineV2KVQuantizationByModel == ["model-a": "balanced"])
        #expect(backend.engineV2KVCheckpointQuantization == "native")
        #expect(backend.engineV2KVCheckpointQuantizationByModel
            == ["model-a": "k8v8", "model-b": "balanced"])

        let standalone = StandaloneServerConfig(
            engineV2KVQuantization: backend.engineV2KVQuantization,
            engineV2KVQuantizationByModel: backend.engineV2KVQuantizationByModel,
            engineV2KVCheckpointQuantization: backend.engineV2KVCheckpointQuantization,
            engineV2KVCheckpointQuantizationByModel: backend.engineV2KVCheckpointQuantizationByModel)
        #expect(standalone.engineV2KVQuantization == "k8v4")
        #expect(standalone.engineV2KVQuantizationByModel == ["model-a": "balanced"])
        #expect(standalone.engineV2KVCheckpointQuantization == "native")
        #expect(standalone.engineV2KVCheckpointQuantizationByModel
            == ["model-a": "k8v8", "model-b": "balanced"])
    }
}
