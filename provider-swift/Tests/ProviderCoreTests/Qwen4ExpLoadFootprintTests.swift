import Foundation
import Testing

@testable import ProviderCore

@Suite("Qwen4 bounded loading footprint")
struct Qwen4ExpLoadFootprintTests {
    @Test func retainsAllComputeAndSeparateTransientAllowance() throws {
        try withCheckpoint { root, size, excluded in
            let estimate = try #require(Qwen4ExpLoadFootprint.estimate(
                snapshotDir: root, modelType: "qwen4_exp", sizeBytes: size,
                offloadedBytes: excluded, offloadEnabled: true))
            #expect(estimate.residentBytes == size - excluded)
            #expect(estimate.transientBytes >= 1 << 30)
            #expect(estimate.totalBytes > size - excluded)
            // The payload contains both MTP and vision; only the PLE table is
            // excluded. Tiny fixtures do not establish physical-hardware fit.
            #expect(estimate.residentBytes >= 64 + 16 + 16)
        }
    }

    @Test func offloadAndNativeFamilyAreRequired() throws {
        try withCheckpoint { root, size, excluded in
            #expect(Qwen4ExpLoadFootprint.estimate(snapshotDir: root, modelType: "qwen4_exp",
                sizeBytes: size, offloadedBytes: excluded, offloadEnabled: false) == nil)
            for type in ["qwen3_5", "gemma4", "nemotron_h", "custom_qwen4_exp"] {
                #expect(Qwen4ExpLoadFootprint.estimate(snapshotDir: root, modelType: type,
                    sizeBytes: size, offloadedBytes: excluded, offloadEnabled: true) == nil)
            }
            #expect(Qwen4ExpLoadFootprint.estimate(snapshotDir: root, modelType: "qwen4_exp",
                sizeBytes: size, offloadedBytes: excluded + 1, offloadEnabled: true) == nil)
            #expect(Qwen4ExpLoadFootprint.estimate(snapshotDir: root, modelType: "qwen4_exp",
                sizeBytes: size + 1, offloadedBytes: excluded, offloadEnabled: true) == nil)
        }
    }

    @Test func fp16ConversionKeepsTheLegacyAllowance() throws {
        try withCheckpoint(computeDType: "F16") { root, size, excluded in
            #expect(Qwen4ExpLoadFootprint.estimate(snapshotDir: root, modelType: "qwen4_exp",
                sizeBytes: size, offloadedBytes: excluded, offloadEnabled: true) == nil)
        }
    }

    @Test(arguments: ["unindexed.safetensors", ".hidden.safetensors", "nested/extra.safetensors"])
    func unindexedPayloadCannotEvadeAllowance(relativePath: String) throws {
        try withCheckpoint { root, size, excluded in
            let destination = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: root.appendingPathComponent("weights.safetensors"),
                to: destination)
            #expect(Qwen4ExpLoadFootprint.estimate(snapshotDir: root, modelType: "qwen4_exp",
                sizeBytes: size, offloadedBytes: excluded, offloadEnabled: true) == nil)
        }
    }

    @Test func indexMustDescribeEveryTensorExactlyOnce() throws {
        try withCheckpoint { root, size, excluded in
            let url = root.appendingPathComponent("model.safetensors.index.json")
            let data = try Data(contentsOf: url)
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var map = try #require(object["weight_map"] as? [String: String])
            map.removeValue(forKey: "mtp.norm.weight")
            object["weight_map"] = map
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            #expect(Qwen4ExpLoadFootprint.estimate(snapshotDir: root, modelType: "qwen4_exp",
                sizeBytes: size, offloadedBytes: excluded, offloadEnabled: true) == nil)
        }
    }

    @Test func loadAllowanceWireIsOptionalAndExact() throws {
        let legacy = ModelInfo(id: "legacy", sizeBytes: 100, estimatedMemoryGb: 1)
        let data = try JSONEncoder().encode(legacy)
        #expect(!String(decoding: data, as: UTF8.self).contains("native_load_transient_bytes"))
        #expect(try JSONDecoder().decode(ModelInfo.self, from: data).nativeLoadTransientBytes == nil)
        var native = legacy
        native.nativeLoadTransientBytes = 6_264_197_720
        let roundTrip = try JSONDecoder().decode(ModelInfo.self, from: JSONEncoder().encode(native))
        #expect(roundTrip.nativeLoadTransientBytes == native.nativeLoadTransientBytes)
    }

    @Test func changedAllocationLayoutFailsClosedBeforeLoading() throws {
        try withCheckpoint { root, size, excluded in
            let estimate = try #require(Qwen4ExpLoadFootprint.estimate(
                snapshotDir: root, modelType: "qwen4_exp", sizeBytes: size,
                offloadedBytes: excluded, offloadEnabled: true))
            var info = ModelInfo(id: "native", modelType: "qwen4_exp", sizeBytes: size,
                estimatedMemoryGb: Double(estimate.totalBytes) / 1_073_741_824,
                ssdOffloadedWeightBytes: excluded, nativeLoadTransientBytes: estimate.transientBytes)
            #expect(Qwen4ExpLoadFootprint.isCurrent(info, directory: root))
            info.nativeLoadTransientBytes = estimate.transientBytes - 1
            #expect(!Qwen4ExpLoadFootprint.isCurrent(info, directory: root))
            info.nativeLoadTransientBytes = estimate.transientBytes
            try Data(#"{"model_type":"qwen3_5"}"#.utf8)
                .write(to: root.appendingPathComponent("config.json"))
            #expect(!Qwen4ExpLoadFootprint.isCurrent(info, directory: root))
        }
    }

    private func withCheckpoint(
        computeDType: String = "BF16",
        _ body: (URL, UInt64, UInt64) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen4-load-footprint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = [
            "language_model.model.layers.1.ple.ngram_embedding.shards.0.weight",
            "language_model.model.layers.0.mlp.switch_mlp.gate_proj.weight",
            "language_model.model.layers.0.mlp.switch_mlp.up_proj.weight",
            "vision_tower.norm.weight", "mtp.norm.weight",
        ]
        var tensors: [String: Any] = [:]
        var map: [String: String] = [:]
        var offset = 0
        for (index, key) in keys.enumerated() {
            let dtype = index == 0 ? "U32" : computeDType
            let count = index < 3 ? 16 : 8
            let bytes = count * (dtype == "U32" ? 4 : 2)
            tensors[key] = ["dtype": dtype, "shape": [count], "data_offsets": [offset, offset + bytes]]
            map[key] = "weights.safetensors"
            offset += bytes
        }
        let header = try JSONSerialization.data(withJSONObject: tensors)
        var length = UInt64(header.count).littleEndian
        var payload = withUnsafeBytes(of: &length) { Data($0) }
        payload.append(header)
        payload.append(Data(repeating: 0, count: offset))
        try payload.write(to: root.appendingPathComponent("weights.safetensors"))
        try JSONSerialization.data(withJSONObject: ["weight_map": map])
            .write(to: root.appendingPathComponent("model.safetensors.index.json"))
        try Data(#"{"model_type":"qwen4_exp"}"#.utf8)
            .write(to: root.appendingPathComponent("config.json"))
        try body(root, UInt64(payload.count), 64)
    }
}
