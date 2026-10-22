import Foundation
import MLX
import MLXLMCommon
@testable import MLXLLM
@testable import MLXVLM

/// Tiny mixed NVFP4/FP8 Super checkpoint for validating the runner and its
/// scripts. Same geometry as the provider test fixture with an image tower
/// (SuperInstalledFixture with 3-channel, 16-pixel-patch RADIO). Synthetic
/// weights and tokenizer: no quality, speed or memory claim applies to the
/// real checkpoint.
enum RunnerSyntheticFixture {
    private struct Tensor {
        let dtype: String
        let shape: [Int]
        let data: Data
    }

    static func model() throws -> NemotronSuperModel {
        let language = NemotronHModel(NemotronHConfiguration(vocabSize: 32, hiddenSize: 16,
            numHiddenLayers: 3, numAttentionHeads: 1, numKeyValueHeads: 1,
            mambaNumHeads: 1, mambaHeadDim: 16, ssmStateSize: 4, convKernel: 4, nGroups: 1,
            intermediateSize: 16, moeIntermediateSize: 16, moeSharedExpertIntermediateSize: 16,
            nRoutedExperts: 2, numExpertsPerTok: 1, hybridOverridePattern: "M*E", headDim: 16))
        let tower = NemotronRadio(NemotronRadioDimensions(width: 2, layers: 1, heads: 1,
            channels: 3, patch: 16, positionSide: 32, prefix: 1, mlpWidth: 3))
        let images = NemotronSuperImageComposition(tower: tower,
            projector: NemotronSuperVisionProjector(visionWidth: 2, hiddenWidth: 3, outputWidth: 16),
            width: 16, imageTokenID: 18)
        return try NemotronSuperModel(languageModel: language, imageComposition: images)
    }

    /// One attention layer x (K+V) x one KV head x head_dim 16 x fp16.
    static let fp16KVBytesPerToken = 64
    static let eosTokenIDs: Set<Int> = [31]

    /// Writes two shards and returns a source whose shard SHA-256 values were
    /// computed from the written bytes (the fixture has no external pin).
    static func writeCheckpoint(to directory: URL) throws -> ModelOptCheckpointSource {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let tensors = try tensors()
        var files: [String: ModelOptTensorFile] = [:]
        var map: [String: String] = [:]
        // Consecutive tensor/scale keys are split across shards, as in the test fixture.
        let keys = tensors.keys.sorted()
        for shard in 0..<2 {
            let name = "fixture-\(shard).safetensors"
            var header: [String: Any] = [:]
            var payload = Data()
            for (index, key) in keys.enumerated() where index % 2 == shard {
                let tensor = tensors[key]!
                let low = payload.count
                payload.append(tensor.data)
                header[key] = ["dtype": tensor.dtype, "shape": tensor.shape,
                               "data_offsets": [low, payload.count]]
                map[key] = name
            }
            let json = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
            var length = UInt64(json.count).littleEndian
            var bytes = withUnsafeBytes(of: &length) { Data($0) }
            bytes.append(json)
            bytes.append(payload)
            let url = directory.appendingPathComponent(name)
            try bytes.write(to: url)
            files[name] = try ModelOptTensorFile(url: url, sha256: runnerSHA256(bytes))
        }
        let index = try JSONSerialization.data(withJSONObject: ["weight_map": map], options: [.sortedKeys])
        try index.write(to: directory.appendingPathComponent("model.safetensors.index.json"))
        return try ModelOptCheckpointSource(indexData: index, indexSHA256: runnerSHA256(index), files: files)
    }

    private static func scalar(_ value: Float) -> Tensor {
        var bits = value.bitPattern.littleEndian
        return Tensor(dtype: "F32", shape: [], data: withUnsafeBytes(of: &bits) { Data($0) })
    }

    private static func tensors() throws -> [String: Tensor] {
        var result: [String: Tensor] = [:]
        for (name, value) in try model().parameters().flattened() {
            let source = name.replacingOccurrences(of: "image_composition.", with: "")
            let data = value.asData()
            result[source] = Tensor(dtype: "F32", shape: data.shape, data: data.data)
        }
        for prefix in ["language_model.backbone.layers.0.mixer.in_proj", "language_model.lm_head"] {
            let old = result[prefix + ".weight"]!
            result[prefix + ".weight"] = Tensor(dtype: "F8_E4M3", shape: old.shape,
                data: Data(repeating: 0, count: old.shape.reduce(1, *)))
            result[prefix + ".input_scale"] = scalar(1)
            result[prefix + ".weight_scale"] = scalar(1)
        }
        let root = "language_model.backbone.layers.2.mixer"
        for (native, raw) in [("fc1", "up_proj"), ("fc2", "down_proj")] {
            let old = result.removeValue(forKey: root + ".switch_mlp." + native + ".weight")!
            for expert in 0..<old.shape[0] {
                let prefix = root + ".experts.\(expert)." + raw
                result[prefix + ".weight"] = Tensor(dtype: "U8", shape: [16, 8], data: Data(repeating: 0, count: 128))
                result[prefix + ".weight_scale"] = Tensor(dtype: "F8_E4M3", shape: [16, 1],
                    data: Data(repeating: 56, count: 16))
                result[prefix + ".weight_scale_2"] = scalar(1)
                result[prefix + ".input_scale"] = scalar(1)
            }
        }
        // Retained MTP and image metadata are accounted for, never executed.
        result["language_model.mtp.fixture.weight"] = scalar(1)
        result["vision_model.summary_idxs"] = Tensor(dtype: "I64", shape: [2], data: Data(repeating: 0, count: 16))
        return result
    }
}

/// Scripted tokenizer whose prompt length follows the request: one token per
/// whitespace-separated word (ids 3...17), one placeholder (18) per image part,
/// framed by 1 and 2. It never emits the image id or EOS (31) for text, so the
/// benchmark's context-length calibration is exercised. No parity claim.
struct RunnerSyntheticTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        text.split(whereSeparator: \.isWhitespace).map { word in
            3 + Int(word.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 } % 15)
        }
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.map { $0 == 0 ? "x" : "p" }.joined()
    }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { id == 0 ? "x" : "p" }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] { render(messages) }
    func applyChatTemplate(messages: [[String: any Sendable]], chatTemplate: String) throws -> [Int] {
        render(messages)
    }
    func applyChatTemplate(messages: [[String: any Sendable]], chatTemplate: String,
        tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
        render(messages)
    }

    private func render(_ messages: [[String: any Sendable]]) -> [Int] {
        var tokens = [1]
        for message in messages {
            if let text = message["content"] as? String {
                tokens += encode(text: text, addSpecialTokens: false)
            } else if let parts = message["content"] as? [[String: any Sendable]] {
                for part in parts {
                    if part["type"] as? String == "text", let text = part["text"] as? String {
                        tokens += encode(text: text, addSpecialTokens: false)
                    } else if part["type"] as? String == "image_url" || part["type"] as? String == "image" {
                        tokens.append(18)
                    }
                }
            }
        }
        return tokens + [2]
    }
}
