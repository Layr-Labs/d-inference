import Foundation
import Testing
@testable import ProviderCoreFoundation

private struct GLMFootprintMetadata {
    var config: [String: Any] = [
        "model_type": "glm5_next",
        "text_config": ["model_type": "glm5_next_text", "num_hidden_layers": 1,
                        "num_nextn_predict_layers": 1, "n_routed_experts": 2,
                        "num_experts_per_tok": 1],
        "vision_config": ["model_type": "glm5_next_vision"],
        "quantization": ["bits": 4, "group_size": 64, "mode": "affine"],
    ]
    var tensors: [String: Any] = [:]
    var files: [String: UInt64] = ["tokenizer.json": 9, "tokenizer_config.json": 7,
                                 "chat_template.jinja": 5, "processor_config.json": 3]
    var payload: UInt64 = 0

    init() {
        for name in ["lm_head.weight", "model.language_model.layers.0.mlp.experts.0.gate_proj.weight",
                     "model.language_model.layers.0.mlp.experts.1.gate_proj.weight",
                     "model.language_model.layers.1.self_attn.q_b_proj.weight"] {
            tensors[name] = ["dtype": "U32", "shape": [2, 8], "data_offsets": [payload, payload + 64]]
            payload += 64
        }
        tensors["model.visual.blocks.0.attn.qkv.weight"] = [
            "dtype": "BF16", "shape": [2, 4], "data_offsets": [payload, payload + 16]]
        payload += 16
    }

    func estimate(indexOverride: [String: Any]? = nil) throws -> GLM5NextDiscoveryLoadFootprint.Estimate? {
        let configData = try JSONSerialization.data(withJSONObject: config, options: .sortedKeys)
        let index: [String: Any] = indexOverride ?? [
            "metadata": ["total_size": payload],
            "weight_map": Dictionary(uniqueKeysWithValues: tensors.keys.map { ($0, "weights.safetensors") }),
        ]
        let indexData = try JSONSerialization.data(withJSONObject: index, options: .sortedKeys)
        var source = files
        source["config.json"] = UInt64(configData.count)
        source["model.safetensors.index.json"] = UInt64(indexData.count)
        source["weights.safetensors"] = payload + 512
        return GLM5NextDiscoveryLoadFootprint.estimate(
            configuration: configData, index: indexData, files: source,
            readHeader: { _ in .init(tensors: tensors, fileBytes: payload + 512, payloadBytes: payload) })
    }
}

@Suite struct GLM5NextDiscoveryLoadFootprintTests {
    @Test func pricesAllExpertsMTPVisionAndNonWeightFiles() throws {
        var fixture = GLMFootprintMetadata()
        let quote = try #require(fixture.estimate())
        let native: UInt64 = 2 * 64 + 128 + 2 * 16 + (257 << 20)
        #expect(quote.nativeTransientBytes == native)
        #expect(quote.tokenizerAllowanceBytes == 64 << 20)
        #expect(quote.supplementBytes == native + (64 << 20))
        #expect(quote.totalBytes == quote.sourceBytes + (quote.sourceBytes + 4) / 5 + quote.supplementBytes)
        #expect(quote.storedBytes == fixture.payload + 512)
        // The active expert count is never a discount on the full source/bank.
        var text = try #require(fixture.config["text_config"] as? [String: Any])
        text["num_experts_per_tok"] = 2
        fixture.config["text_config"] = text
        #expect(try fixture.estimate()?.nativeTransientBytes == native)
        fixture.files["tokenizer.json"] = 20 << 20
        let expanded = try #require(fixture.estimate())
        #expect(expanded.tokenizerAllowanceBytes == (expanded.sourceBytes - expanded.storedBytes) * 8)
    }

    @Test func refusesUnknownRolesBadFramingAndOversizedMetadata() throws {
        let base = GLMFootprintMetadata()
        var bad = base
        bad.config["model_type"] = "GLM5_NEXT"
        #expect(try bad.estimate() == nil)
        bad = base
        bad.config["quantization"] = ["bits": true, "group_size": 64, "mode": "affine"]
        #expect(try bad.estimate() == nil)
        bad.config["quantization"] = ["bits": 8, "group_size": 64, "mode": "affine"]
        #expect(try bad.estimate() == nil)
        bad = base
        bad.config["quantization_config"] = ["bits": 4, "group_size": 32, "mode": "affine"]
        #expect(try bad.estimate() == nil)
        for name in ["unknown.weight", "model.language_model.layers.01.mlp.experts.0.gate_proj.weight",
                     "model.language_model.layers.0.mlp.experts.0.unknown.weight"] {
            bad = base
            bad.tensors[name] = bad.tensors.removeValue(forKey: "model.language_model.layers.0.mlp.experts.0.gate_proj.weight")
            #expect(try bad.estimate() == nil)
        }
        let badOffsets: [[Any]] = [[0, 1], [true, 64], [-1, 63], [0.5, 64.5], [UInt64.max, UInt64.max]]
        for offsets in badOffsets {
            bad = base
            bad.tensors["lm_head.weight"] = ["dtype": "U32", "shape": [2, 8], "data_offsets": offsets]
            #expect(try bad.estimate() == nil)
        }
        let badShapes: [[Any]] = [[true, 8], [0, 8], [-1, 8], [1.5, 8], [UInt64.max, 8]]
        for shape in badShapes {
            bad = base
            bad.tensors["lm_head.weight"] = ["dtype": "U32", "shape": shape, "data_offsets": [0, 64]]
            #expect(try bad.estimate() == nil)
        }
        bad = base
        bad.files["tokenizer.json"] = (512 << 20) + 1
        #expect(try bad.estimate() == nil)
        bad = base
        bad.files["unknown.json"] = 1
        #expect(try bad.estimate() == nil)
        bad = base
        bad.files["extra.bin"] = 1
        #expect(try bad.estimate() == nil)
        let incompleteIndex: [String: Any] = ["metadata": ["total_size": base.payload], "weight_map": ["lm_head.weight": "weights.safetensors"]]
        #expect(try base.estimate(indexOverride: incompleteIndex) == nil)
        let traversal: [String: Any] = ["metadata": ["total_size": base.payload], "weight_map": ["lm_head.weight": "../weights.safetensors"]]
        #expect(try base.estimate(indexOverride: traversal) == nil)
    }

    @Test func checkedArithmeticAndVerifiedRawProjection() throws {
        struct Raw: Decodable {
            let storedBytes, nonWeightBytes, largestTensorBytes, largestExpertBankBytes, visionBytes: UInt64
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let raw = try JSONDecoder().decode(Raw.self, from: Data(contentsOf:
            root.appendingPathComponent("fixtures/models/glm53-flash/load-footprint.json")))
        let quote = try GLM5NextDiscoveryLoadFootprint.quotation(
            storedBytes: raw.storedBytes, nonWeightBytes: raw.nonWeightBytes,
            largestTensor: raw.largestTensorBytes, largestExpertBank: raw.largestExpertBankBytes,
            visionBytes: raw.visionBytes)
        let disk = raw.storedBytes + raw.nonWeightBytes
        let expected = disk + (disk + 4) / 5 + 2 * raw.largestTensorBytes + raw.largestExpertBankBytes
            + 2 * raw.visionBytes + (257 << 20) + max(64 << 20, 8 * raw.nonWeightBytes)
        #expect(quote.totalBytes == expected)
        #expect(quote.totalBytes == 222_714_752_471)
        #expect(quote.supplementBytes == 4_624_662_032)
        for stored in [UInt64(0), UInt64.max, UInt64(Int64.max)] {
            #expect(throws: (any Error).self) {
                try GLM5NextDiscoveryLoadFootprint.quotation(
                    storedBytes: stored, nonWeightBytes: 1, largestTensor: 1,
                    largestExpertBank: 1, visionBytes: 1)
            }
        }
        #expect(throws: (any Error).self) {
            try GLM5NextDiscoveryLoadFootprint.quotation(
                storedBytes: 100, nonWeightBytes: UInt64.max / 4,
                largestTensor: 1, largestExpertBank: 1, visionBytes: 1)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLM53_RAW_HEADER_FIXTURE_DIR"] != nil))
    func completeRetainedRawHeadersMatchProjectionWithoutPayloadReads() throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GLM53_RAW_HEADER_FIXTURE_DIR"]))
        let audit = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("header-audit.json"))) as! [[String: Any]]
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("metadata.json"))) as! [String: Any]
        #expect(metadata["sha"] as? String == "76add2a341a1cd90ad0e86bb69839ea9c35827c6")
        let siblings = metadata["siblings"] as! [[String: Any]]
        let files = Dictionary(uniqueKeysWithValues: siblings.compactMap { entry -> (String, UInt64)? in
            guard let name = entry["rfilename"] as? String, ModelScanner.isIntegrityFile(name),
                let size = entry["size"] as? UInt64 else { return nil }
            return (name, size)
        })
        var reads = 0
        let quote = GLM5NextDiscoveryLoadFootprint.estimate(
            configuration: try Data(contentsOf: root.appendingPathComponent("config.json")),
            index: try Data(contentsOf: root.appendingPathComponent("model.safetensors.index.json")), files: files,
            readHeader: { name in
                guard let item = audit.first(where: { $0["file"] as? String == name }),
                    let file = item["total_bytes"] as? UInt64, let header = item["header_bytes"] as? UInt64,
                    let data = try? Data(contentsOf: root.appendingPathComponent("headers/\(name).json")),
                    UInt64(data.count) == header,
                    let digest = WeightHasher.hashSingleFile(at: root.appendingPathComponent("headers/\(name).json")),
                    digest.map({ String(format: "%02x", $0) }).joined() == item["header_sha256"] as? String,
                    let tensors = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                reads += 1
                return .init(tensors: tensors, fileBytes: file, payloadBytes: file - header - 8)
            })
        #expect(reads == 43)
        #expect(try #require(quote).totalBytes == 222_714_752_471)
    }
}
