import Foundation
import Testing
import ProviderCoreFoundation
@testable import ProviderCore

@Suite struct GLM5NextDiscoveryTests {
    @Test func metadataOnlyCacheAndProvenanceDirectoriesDoNotChangeQuotation() throws {
        try withGLMDiscoverySnapshot { root in
            let before = try #require(ModelScanner.glm5NextLoadEstimate(snapshotDir: root))
            let info = try #require(ModelScanner.parseModelInfo(snapshotDir: root, modelName: "test/raw"))
            let metadata: [String: Data] = [
                ".cache/huggingface/download/weights.safetensors.metadata": Data("revision\netag\n0\n".utf8),
                ".cache/huggingface/download/tokenizer.json.lock": Data(),
                "_provenance/provider-integrity-manifest.json": Data(#"{"schema_version":1,"files":[]}"#.utf8),
            ]
            for (path, contents) in metadata {
                let file = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: file)
            }
            #expect(ModelScanner.glm5NextLoadEstimate(snapshotDir: root) == before)
            #expect(ModelScanner.parseModelInfo(snapshotDir: root, modelName: info.id) == info)
            #expect(ModelScanner.glm5NextLoadQuotationIsCurrent(info, directory: root))
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("_provenance/provider-integrity-manifest.json").path))
        }
    }

    @Test(arguments: [".cache/hidden.safetensors", ".cache/.hidden.bin", "_provenance/weights.npz",
                      "_provenance/config.json", ".cache/download/tokenizer.json", ".hidden.safetensors"])
    func nestedOrHiddenIntegrityFilesRemainIneligible(path: String) throws {
        try withGLMDiscoverySnapshot { root in
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0]).write(to: file)
            #expect(ModelScanner.glm5NextLoadEstimate(snapshotDir: root) == nil)
            #expect(ModelScanner.parseModelInfo(snapshotDir: root, modelName: "test/raw") == nil)
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test(arguments: ["metadata-file", "payload-file", "directory", "root"])
    func symlinkAliasesRemainIneligible(kind: String) throws {
        try withGLMDiscoverySnapshot { root in
            let alias: URL
            let destination: URL
            if kind == "root" {
                alias = root.appendingPathExtension("alias")
                destination = root
            } else {
                let directory = root.appendingPathComponent(".cache")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                alias = directory.appendingPathComponent("alias")
                destination = kind == "metadata-file" ? root.appendingPathComponent("README.md")
                    : kind == "payload-file" ? root.appendingPathComponent("weights.safetensors") : root
            }
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: destination)
            defer { try? FileManager.default.removeItem(at: alias) }
            #expect(ModelScanner.glm5NextLoadEstimate(snapshotDir: kind == "root" ? alias : root) == nil)
            #expect(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @Test func metadataDirectoryDepthIsBounded() throws {
        try withGLMDiscoverySnapshot { root in
            var directory = root
            for _ in 0..<8 { directory.appendPathComponent("metadata") }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #expect(ModelScanner.glm5NextLoadEstimate(snapshotDir: root) != nil)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("too-deep"), withIntermediateDirectories: false)
            #expect(ModelScanner.glm5NextLoadEstimate(snapshotDir: root) == nil)
        }
    }

    @Test(arguments: [false, true])
    func metadataFileAndAggregateSizesAreBounded(aggregate: Bool) throws {
        try withGLMDiscoverySnapshot { root in
            let directory = root.appendingPathComponent("_provenance")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Sparse test files exercise stat bounds without allocating or reading
            // the large payload. Every file in this test belongs to this fixture.
            for index in 0..<(aggregate ? 3 : 1) {
                let file = directory.appendingPathComponent("receipt-\(index).json")
                try Data().write(to: file)
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.truncate(atOffset: aggregate ? 24 << 20 : (32 << 20) + 1)
            }
            #expect(ModelScanner.glm5NextLoadEstimate(snapshotDir: root) == nil)
        }
    }

    @Test func metadataEntryCountIsBounded() throws {
        try withGLMDiscoverySnapshot { root in
            let directory = root.appendingPathComponent(".cache")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let existing = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count
            for index in 0..<(4096 - existing) {
                try Data().write(to: directory.appendingPathComponent("entry-\(index).metadata"))
            }
            #expect(ModelScanner.glm5NextLoadEstimate(snapshotDir: root) != nil)
            try Data().write(to: directory.appendingPathComponent("one-too-many.metadata"))
            #expect(ModelScanner.glm5NextLoadEstimate(snapshotDir: root) == nil)
        }
    }

    @Test func malformedGLMHasNoLoadableGenericFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("glm-discovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0, count: 1024).write(to: root.appendingPathComponent("weights.safetensors"))
        let config = root.appendingPathComponent("config.json")
        try Data(#"{"model_type":"glm5_next"}"#.utf8).write(to: config)
        #expect(ModelScanner.parseModelInfo(snapshotDir: root, modelName: "test/llama") == nil)
        // Identity-like names do not select GLM pricing for another architecture.
        try Data(#"{"model_type":"llama"}"#.utf8).write(to: config)
        let other = try #require(ModelScanner.parseModelInfo(snapshotDir: root, modelName: "test/GLM5-Next-Q4"))
        #expect(other.nativeLoadTransientBytes == nil)
        #expect(other.estimatedMemoryGb == Double(other.sizeBytes) / 1_073_741_824 * 1.2)
        let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(other)) as! [String: Any]
        #expect(wire["native_load_transient_bytes"] == nil)
        #expect(wire["ssd_offloaded_weight_bytes"] == nil)
    }
}

/// Minimal header-pricing fixture, not a native architecture/support fixture.
/// No real checkpoint, native arrays or payload hashing is involved.
private func withGLMDiscoverySnapshot(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("glm-discovery-valid-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let config: [String: Any] = [
        "model_type": "glm5_next",
        "text_config": ["model_type": "glm5_next_text", "num_hidden_layers": 1,
                        "num_nextn_predict_layers": 1, "n_routed_experts": 2],
        "vision_config": ["model_type": "glm5_next_vision"],
        "quantization": ["bits": 4, "group_size": 64, "mode": "affine"],
    ]
    var tensors: [String: Any] = [:]
    var payloadBytes = 0
    for name in ["lm_head.weight", "model.language_model.layers.0.mlp.experts.0.gate_proj.weight",
                 "model.language_model.layers.0.mlp.experts.1.gate_proj.weight",
                 "model.language_model.layers.1.self_attn.q_b_proj.weight"] {
        tensors[name] = ["dtype": "U32", "shape": [2, 8], "data_offsets": [payloadBytes, payloadBytes + 64]]
        payloadBytes += 64
    }
    tensors["model.visual.blocks.0.attn.qkv.weight"] = [
        "dtype": "BF16", "shape": [2, 4], "data_offsets": [payloadBytes, payloadBytes + 16]]
    payloadBytes += 16
    let header = try JSONSerialization.data(withJSONObject: tensors, options: .sortedKeys)
    var headerBytes = UInt64(header.count).littleEndian
    var shard = withUnsafeBytes(of: &headerBytes) { Data($0) }
    shard.append(header)
    shard.append(Data(repeating: 0, count: payloadBytes))
    let files: [String: Data] = [
        "config.json": try JSONSerialization.data(withJSONObject: config, options: .sortedKeys),
        "model.safetensors.index.json": try JSONSerialization.data(withJSONObject: [
            "metadata": ["total_size": payloadBytes],
            "weight_map": Dictionary(uniqueKeysWithValues: tensors.keys.map { ($0, "weights.safetensors") }),
        ], options: .sortedKeys),
        "weights.safetensors": shard, "tokenizer.json": Data("{}".utf8),
        "tokenizer_config.json": Data(#"{"chat_template":"fixture"}"#.utf8),
        "chat_template.jinja": Data("fixture".utf8), "processor_config.json": Data("{}".utf8),
        "README.md": Data("metadata only".utf8),
    ]
    for (name, bytes) in files { try bytes.write(to: root.appendingPathComponent(name)) }
    try body(root)
}
