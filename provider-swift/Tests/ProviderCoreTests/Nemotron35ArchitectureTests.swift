import Foundation
import Testing

@testable import ProviderCore

@Suite("Nemotron Lightning pre-load architecture")
struct Nemotron35ArchitectureTests {
    @Test("standalone Mamba and MoE blocks do not inflate growing KV")
    func blockSequenceDefinesAttentionLayers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nemotron-architecture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config.json")
        try Data("""
            {"model_type":"nemotron_h", "num_hidden_layers":4,
             "num_key_value_heads":2, "num_attention_heads":32, "head_dim":128,
             "layers_block_type":["mamba","moe","attention","mlp"]}
            """.utf8).write(to: config)
        let architecture = KVEstimation.parseModelArchitecture(at: config)
        #expect(architecture.layerTypes == ["mamba", "moe", "attention", "mlp"])
        let bytes = KVEstimation.computeKVBytesPerToken(
            numLayers: 4, kvHeads: 2, headDim: 128, numKvSharedLayers: 0,
            globalHeadDim: nil, numGlobalKvHeads: nil,
            slidingWindowPattern: nil, layerTypes: architecture.layerTypes)
        // Pre-load estimate uses fp16; loaded native types are probed separately.
        #expect(bytes == 2 * 2 * 128 * 2)
    }
}
