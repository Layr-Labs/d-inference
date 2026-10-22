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
        let quote = try #require(try fixture.estimate())
        let native: UInt64 = 2 * 64 + 128 + 2 * 16 + (257 << 20)
        #expect(quote.nativeTransientBytes == native)
        #expect(quote.tokenizerAllowanceBytes == 64 << 20)
        // Tiny sources take the 1-GiB residual floor; no disk × 1.2 padding.
        #expect(quote.residualAllowanceBytes == 1 << 30)
        #expect(quote.supplementBytes == native + (64 << 20) + (1 << 30))
        #expect(quote.totalBytes == quote.sourceBytes + quote.supplementBytes)
        #expect(quote.storedBytes == fixture.payload + 512)
        // The active expert count is never a discount on the full source/bank.
        var text = try #require(fixture.config["text_config"] as? [String: Any])
        text["num_experts_per_tok"] = 2
        fixture.config["text_config"] = text
        #expect(try fixture.estimate()?.nativeTransientBytes == native)
        fixture.files["tokenizer.json"] = 20 << 20
        let expanded = try #require(try fixture.estimate())
        #expect(expanded.tokenizerAllowanceBytes == (expanded.sourceBytes - expanded.storedBytes) * 8)
    }

    /// The NVFP4 hybrid is quoted from its exact stored bytes: U8 FP8 scales
    /// and the F32 per-tensor scale count byte for byte; nothing is padded.
    @Test func pricesNVFP4ExpertTensorsFromExactBytes() throws {
        var fixture = GLMFootprintMetadata()
        var quantization: [String: Any] = ["bits": 4, "group_size": 64, "mode": "affine"]
        let nvfp4: [String: Any] = ["bits": 4, "group_size": 16, "mode": "nvfp4"]
        for expert in 0 ..< 2 {
            let base = "model.language_model.layers.0.mlp.experts.\(expert).gate_proj"
            quantization[base] = nvfp4
            fixture.tensors[base + ".scales"] = [
                "dtype": "U8", "shape": [2, 4], "data_offsets": [fixture.payload, fixture.payload + 8]]
            fixture.payload += 8
            fixture.tensors[base + ".weight_scale_2"] = [
                "dtype": "F32", "shape": expert == 0 ? [] : [1],
                "data_offsets": [fixture.payload, fixture.payload + 4]]
            fixture.payload += 4
        }
        // Without the NVFP4 declaration the byte tensors are refused.
        #expect(try fixture.estimate() == nil)
        fixture.config["quantization"] = quantization
        let quote = try #require(try fixture.estimate())
        #expect(quote.storedBytes == fixture.payload + 512)
        // Each stacked bank is one tensor role; the packed words stay largest.
        #expect(quote.nativeTransientBytes == 2 * 64 + 128 + 2 * 16 + (257 << 20))

        var bad = fixture
        quantization["model.language_model.layers.0.self_attn.q_b_proj"] = ["bits": 8, "group_size": 64, "mode": "affine"]
        bad.config["quantization"] = quantization
        #expect(try bad.estimate() == nil)
        bad = fixture
        bad.tensors["model.language_model.layers.0.mlp.experts.0.gate_proj.scales"] = [
            "dtype": "U8", "shape": [8], "data_offsets": [272, 280]]
        #expect(try bad.estimate() == nil)
        bad = fixture
        bad.tensors["model.language_model.layers.0.mlp.experts.0.gate_proj.weight_scale_2"] = [
            "dtype": "BF16", "shape": [2], "data_offsets": [280, 284]]
        #expect(try bad.estimate() == nil)
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

    /// The published NVFP4 `config.json` is ~10 MB of per-module quantization
    /// metadata; discovery accepts it up to the native loader's 32 MiB bound.
    @Test func acceptsNVFP4SizedConfigurationUpToTheNativeLoaderBound() throws {
        #expect(GLM5NextDiscoveryLoadFootprint.maximumConfigurationBytes == 32 << 20)
        func padded(toBytes target: Int) throws -> GLMFootprintMetadata {
            var fixture = GLMFootprintMetadata()
            fixture.config["padding"] = ""
            let overhead = try JSONSerialization.data(withJSONObject: fixture.config, options: .sortedKeys).count
            fixture.config["padding"] = String(repeating: "x", count: target - overhead)
            let size = try JSONSerialization.data(withJSONObject: fixture.config, options: .sortedKeys).count
            #expect(size == target)
            return fixture
        }
        #expect(try padded(toBytes: 10_023_646).estimate() != nil)
        #expect(try padded(toBytes: GLM5NextDiscoveryLoadFootprint.maximumConfigurationBytes).estimate() != nil)
        #expect(try padded(toBytes: GLM5NextDiscoveryLoadFootprint.maximumConfigurationBytes + 1).estimate() == nil)
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
        let expected = disk + (disk + 31) / 32 + 2 * raw.largestTensorBytes + raw.largestExpertBankBytes
            + 2 * raw.visionBytes + (257 << 20) + max(64 << 20, 8 * raw.nonWeightBytes)
        #expect(quote.totalBytes == expected)
        #expect(quote.residualAllowanceBytes == 5_679_429_439)
        #expect(quote.totalBytes == 192_045_833_503)
        #expect(quote.supplementBytes == 10_304_091_471)
        // Measured envelope: the staged Q4 target (text + vision) is resident at
        // 177,510,375,680 B MLX-active after load and peaks at 180.89 GB through
        // a 512-token prefill; adding the 4,183,317,120-byte MTP layer keeps the
        // projected peak below the quote, which still fits a 256-GiB Mac's
        // 90% cap after the 5.5-GiB activation and 1-GiB minimum-KV headroom.
        let measuredPeakWithMTP: UInt64 = 180_890_000_000 + 4_183_317_120
        #expect(quote.totalBytes > measuredPeakWithMTP + quote.residualAllowanceBytes)
        let cap = UInt64(Double(UInt64(256) << 30) * 0.9)
        #expect(quote.totalBytes + (11 << 29) + (1 << 30) < cap)
        #expect(GLM5NextDiscoveryLoadFootprint.residualAllowanceBytes(sourceBytes: 32) == 1 << 30)
        #expect(GLM5NextDiscoveryLoadFootprint.residualAllowanceBytes(sourceBytes: 64 << 30) == 2 << 30)
        #expect(GLM5NextDiscoveryLoadFootprint.residualAllowanceBytes(sourceBytes: (64 << 30) + 1)
            == (2 << 30) + 1)
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
        #expect(try #require(quote).totalBytes == 192_045_833_503)
    }
}
