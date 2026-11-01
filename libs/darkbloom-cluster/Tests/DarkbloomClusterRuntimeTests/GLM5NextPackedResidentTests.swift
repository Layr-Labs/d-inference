import Foundation
import MLXLLM
import Testing
@testable import DarkbloomClusterRuntime

/// Actual affine U32 payloads and BF16 scales/offsets, not float tensors behind
/// a packed-storage label. The values represent a constant quantized matrix.
@Suite("GLM serving packed resident lifetime", .serialized)
struct GLM5NextPackedResidentTests {
    private enum Failure: Error { case fence }

    @Test func servingPackedStagesRetainBorrowAndQuarantineProcessLease() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glm-packed-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try GLM5NextMetadataTestFixture(layers: 4)
        var root = try #require(JSONSerialization.jsonObject(with: canonicalJSONData(base.configuration)) as? [String: Any])
        var text = try #require(root["text_config"] as? [String: Any])
        for key in ["hidden_size", "intermediate_size", "moe_intermediate_size", "qk_head_dim",
                    "qk_nope_head_dim", "v_head_dim", "q_lora_rank", "kv_lora_rank", "index_head_dim"] {
            text[key] = 64
        }
        var linear = try #require(text["linear_attn_config"] as? [String: Any])
        linear["head_dim"] = 64; text["linear_attn_config"] = linear
        root["text_config"] = text
        var vision = try #require(root["vision_config"] as? [String: Any])
        vision["out_hidden_size"] = 64; root["vision_config"] = vision
        root["quantization"] = ["bits": 4, "group_size": 64, "mode": "affine"]
        let config = try JSONSerialization.data(withJSONObject: root, options: .sortedKeys)
        let configuration = try JSONDecoder().decode(GLM5NextConfiguration.self, from: config)
        let tensors = try GLM5NextWeightInventory.expectedTensors(configuration: configuration,
            storage: .vontraQ4, shard: "packed.safetensors")
        #expect(tensors.contains { $0.dtype == "U32" })
        var header: [String: Any] = [:], payload = Data()
        for tensor in tensors {
            let begin = payload.count
            for index in 0..<tensor.shape.reduce(1, *) {
                let value: Float
                if tensor.name.hasSuffix(".scales") { value = 0.01 }
                else if tensor.name.contains("norm.weight") || tensor.name.hasSuffix("_scale") { value = 1 }
                else if tensor.name.hasSuffix("A_log") { value = -0.7 }
                else if tensor.name.hasSuffix("dt_bias") { value = -0.2 }
                else if tensor.name.hasSuffix(".biases") || tensor.name.hasSuffix("_base") { value = 0 }
                else { value = Float(index % 11 - 5) * 0.025 }
                if tensor.dtype == "BF16" {
                    var word = UInt16(truncatingIfNeeded: value.bitPattern >> 16).littleEndian
                    withUnsafeBytes(of: &word) { payload.append(contentsOf: $0) }
                } else {
                    var word = (tensor.dtype == "U32" ? UInt32(0x1111_1111) : value.bitPattern).littleEndian
                    withUnsafeBytes(of: &word) { payload.append(contentsOf: $0) }
                }
            }
            header[tensor.name] = ["shape": tensor.shape, "dtype": tensor.dtype,
                "data_offsets": [begin, payload.count]]
        }
        var encoded = try JSONSerialization.data(withJSONObject: header, options: .sortedKeys)
        while encoded.count % 8 != 0 { encoded.append(32) }
        var length = UInt64(encoded.count).littleEndian
        var shard = withUnsafeBytes(of: &length) { Data($0) }
        shard.append(encoded); shard.append(payload)
        let index = try JSONSerialization.data(withJSONObject: [
            "metadata": ["total_size": payload.count],
            "weight_map": Dictionary(uniqueKeysWithValues: tensors.map { ($0.name, $0.shard) })], options: .sortedKeys)
        let documents = ["config.json": config, "model.safetensors.index.json": index, "packed.safetensors": shard]
        for (name, data) in documents { try data.write(to: directory.appendingPathComponent(name)) }
        let identity = GLM5NextArtifactIdentity(repository: "synthetic/glm-packed", revision: String(repeating: "a", count: 40),
            files: documents.mapValues { .init(bytes: $0.count, sha256: sha256($0)) })
        for rank in 0...1 {
            let lease = QwenResidentProcessLease()
            let owner = try GLM5NextResidentStage(directory: directory, expectedIdentity: identity,
                artifactAggregateSHA256: String(repeating: "b", count: 64), storage: .vontraQ4,
                stageIndex: rank, cut: 2, includeMTP: false, executionPolicy: .serving,
                capacityLimitBytes: 8 << 30, executionStateReserveBytes: 1 << 20,
                workspaceReserveBytes: 1 << 20, processLease: lease)
            defer { try? owner.close(peerFence: {}, check: {}) }
            try owner.load(check: {})
            #expect(owner.receipt?.selectedPayloadBytes == owner.resources.summary.selectedStoredBytes)
            weak var model: GLM5NextTextStage?
            do {
                let borrow = try owner.borrowComponent { binding, _ in binding.model }
                model = borrow.value
                #expect(borrow.value.executionPolicy == .serving)
                #expect(throws: ProbeError.self) { try owner.close(peerFence: {}, check: {}) }
            }
            #expect(throws: Failure.self) { try owner.close(peerFence: { throw Failure.fence }, check: {}) }
            #expect(model != nil)
            try owner.close(peerFence: {}, check: {})
            #expect(model == nil && owner.requiresProcessExit)
            #expect(throws: ProbeError.self) { try lease.acquire() }
        }
    }
}
