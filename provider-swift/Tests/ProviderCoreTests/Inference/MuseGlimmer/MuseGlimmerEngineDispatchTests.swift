// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLLM
import Testing

@testable import MLXLMCommon
@testable import ProviderCore

/// The engine side of the generic slot, over a tiny synthetic text tower with
/// the production attention shape. No checkpoint and no downloaded data.
@Suite("Muse Glimmer engine dispatch", .serialized)
struct MuseGlimmerEngineDispatchTests {
    private let modelID = MuseGlimmerModelPolicy.localModelID
    private let capacity = 8 << 20

    private func environment(_ overrides: [String: String] = [:]) -> [String: String] {
        [KVBackendGuardStore.pathEnvKey: "/dev/null"].merging(overrides) { _, explicit in explicit }
    }

    /// 32 query heads over 2 KV heads of 128, as published; four small layers.
    private func tower() throws -> MuseGlimmerTextModel {
        let text: [String: Any] = [
            "hidden_size": 64, "num_hidden_layers": 4, "num_attention_heads": 32,
            "num_key_value_heads": 2, "head_dim": 128, "intermediate_size": 128,
            "sliding_window": 64, "vocab_size": 96, "rope_parameters": ["rope_theta": 500000.0],
        ]
        return MuseGlimmerTextModel(try JSONDecoder().decode(
            MuseGlimmerTextModelConfiguration.self, from: JSONSerialization.data(withJSONObject: text)))
    }

    private func prepare(
        _ selection: EngineV2KVBackendSelection, modelID: String? = nil, environment: [String: String]
    ) throws -> EngineV2Factory.ProductionBackendPreparation {
        try EngineV2Factory.prepareProductionBackend(
            model: tower(), modelID: modelID ?? self.modelID, kvBytesCapacity: capacity,
            maxConcurrentRequests: 2, kvBackend: selection, maxContextLength: 2048, environment: environment)
    }

    @Test("the production adapter describes the tower and carries its paged-only capability")
    func adapter() throws {
        let model = try tower()
        let adapter = try #require(EngineV2Factory.ProductionModelAdapter(model: model))
        #expect(adapter.layerKinds == model.cbv2LayerKinds)
        #expect(adapter.layerKinds.count == 4)
        #expect(adapter.modelCapabilities.supportsPagedKV)
        #expect(adapter.modelCapabilities.requiresPagedKV)
        #expect(EngineV2Factory.cbv2LayerKinds(model: model) == model.cbv2LayerKinds)
        // A complete historical checkpoint needs no token replay.
        #expect((model as any CBv2HistoricalAttentionCheckpointProviding).cbv2SupportsHistoricalAttentionCheckpoint)
    }

    @Test("automatic and explicit paged selections resolve to paged")
    func resolvesPaged() throws {
        for selection in [EngineV2KVBackendSelection.auto, .paged] {
            let prepared = try prepare(selection, environment: environment())
            #expect(prepared.kind == .paged, "\(selection)")
            #expect(prepared.fallbackReason == nil, "\(selection)")
        }
    }

    @Test("nothing serves it contiguous: every other resolution refuses the load")
    func refusesContiguous() {
        // By the loaded model's capability, so under any model id.
        for id in [modelID, MuseGlimmerModelPolicy.catalogModelID, "some/other-id"] {
            #expect(throws: EngineV2ProductionError.self) {
                _ = try prepare(.contiguous, modelID: id, environment: environment())
            }
            #expect(throws: EngineV2ProductionError.self) {
                _ = try prepare(.auto, modelID: id,
                                environment: environment([EngineV2KVBackendPolicy.killSwitchEnvKey: "0"]))
            }
        }
    }

    @Test("media is not advertised: the retained vision configuration selects the text load")
    func textFirst() {
        let configuration: [String: Any] = [
            "model_type": "muse_glimmer", "vision_config": ["model_type": "muse_glimmer_vision"],
            "text_config": ["model_type": "muse_glimmer_text"],
        ]
        for id in [modelID, MuseGlimmerModelPolicy.catalogModelID] {
            #expect(!ModelMediaPolicy.advertisesMedia(configuration, modelID: id))
            #expect(ModelContainerLoading.factorySelection(for: configuration, modelID: id) == .text)
        }
        // The generic rule for other types is unchanged.
        #expect(ModelMediaPolicy.advertisesMedia(["model_type": "llava", "vision_config": [:] as [String: Any]]))
    }

    @Test("a directory that is not the pinned checkpoint does not load")
    func unpinnedDirectoryRefuses() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-glimmer-unpinned-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"model_type":"muse_glimmer","text_config":{"model_type":"muse_glimmer_text"}}"#.utf8)
            .write(to: directory.appendingPathComponent("config.json"))
        try Data([0]).write(to: directory.appendingPathComponent("model.safetensors"))
        await #expect(throws: (any Error).self) {
            _ = try await ModelContainerLoading.loadContainer(from: directory, modelID: modelID)
        }
    }
}
