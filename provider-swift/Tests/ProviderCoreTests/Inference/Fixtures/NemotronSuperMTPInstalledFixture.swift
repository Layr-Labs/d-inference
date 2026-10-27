import CryptoKit
import Foundation
import MLX
import MLXNN
import Testing
@testable import MLXLLM
@testable import MLXLMCommon
@testable import MLXVLM
@testable import ProviderCore

/// Seeded MTP-capable Super installation with a calibrated FP8 output head,
/// NVFP4 target experts and an embedded NVFP4 prediction head, staged through
/// the SDK installer and head loader. Synthetic weights; never official ones.
/// Block output projections are shrunk so the embedding dominates greedy choice,
/// and the head drafts from the seed embedding, so drafts are often but not
/// always accepted.
struct SuperMTPInstalledFixture {
    var seed: UInt64 = 3
    /// nil keeps the one-channel tower that takes direct normalized input;
    /// encoded PNG/JPEG requests need the reference three-channel 16-pixel patch.
    var radioDimensions: NemotronRadioDimensions? = nil
    /// The reference preprocessing's three-channel, 16-pixel-patch layout on a
    /// two-wide tower: what an encoded PNG or JPEG request needs.
    static let encodedImageTower = NemotronRadioDimensions(width: 2, layers: 1, heads: 1,
        channels: 3, patch: 16, positionSide: 32, prefix: 1, mlpWidth: 3)
    static let hidden = 32
    static let vocabulary = 64
    /// Attention head width: 64, the narrowest the paged KV kernels take (64,
    /// 128, 256 or 512); the Super owner serves paged KV only.
    static let attentionHeadDim = 64
    private struct Tensor { let dtype: String; let shape: [Int]; let data: Data }

    static func configuration() -> NemotronHConfiguration {
        NemotronHConfiguration(vocabSize: vocabulary, hiddenSize: hidden, numHiddenLayers: 3,
            numAttentionHeads: 2, numKeyValueHeads: 1, mambaNumHeads: 2, mambaHeadDim: 16,
            ssmStateSize: 8, convKernel: 4, nGroups: 1, intermediateSize: 32,
            moeIntermediateSize: 32, moeSharedExpertIntermediateSize: 32, nRoutedExperts: 4,
            numExpertsPerTok: 2, hybridOverridePattern: "M*E", headDim: attentionHeadDim,
            nSharedExperts: 1,
            numNextnPredictLayers: 1, mtpLayersBlockType: ["attention", "moe"], moeLatentSize: 16)
    }

    private func model() throws -> NemotronSuperModel {
        let images = NemotronSuperImageComposition(tower: NemotronRadio(radioDimensions
            ?? NemotronRadioDimensions(width: 2, layers: 1, heads: 1, channels: 1, patch: 2,
                positionSide: 2, prefix: 1, mlpWidth: 3)),
            projector: NemotronSuperVisionProjector(visionWidth: 2, hiddenWidth: 3,
                outputWidth: Self.hidden),
            width: Self.hidden, imageTokenID: 18)
        return try NemotronSuperModel(languageModel: NemotronHModel(Self.configuration()),
            imageComposition: images)
    }

    /// Keyed initialization only; never the shared global generator.
    private func randomized(_ module: Module, seed: UInt64) -> [(String, MLXArray)] {
        module.parameters().flattened().enumerated().compactMap { index, entry in
            let (name, value) = entry
            let leaf = name.split(separator: ".").last.map(String.init) ?? name
            guard value.dtype == .float32, !["A_log", "D", "dt_bias"].contains(leaf) else {
                return (name, value)
            }
            let noise = MLXRandom.normal(value.shape,
                key: MLXRandom.key(seed &* 1_000_003 &+ UInt64(index)))
            if value.ndim == 1 { return (name, name.contains("norm") ? 1 + 0.1 * noise : 0.1 * noise) }
            return (name, noise / Float(value.dim(-1)).squareRoot())
        }
    }

    private func bytes(_ array: MLXArray, _ dtype: String) -> Tensor {
        let data = array.asData()
        return Tensor(dtype: dtype, shape: data.shape, data: data.data)
    }

    private func scalar(_ value: Float, shape: [Int] = []) -> Tensor {
        var bits = value.bitPattern.littleEndian
        return Tensor(dtype: "F32", shape: shape, data: withUnsafeBytes(of: &bits) { Data($0) })
    }

    private func nvfp4(_ stem: String, input: Int, output: Int, seed: UInt64, scale: Float,
                       into result: inout [String: Tensor]) {
        let packed = MLXRandom.randInt(Int32(0) ..< 256, [output, input / 2], key: MLXRandom.key(seed))
        let blocks = MLXRandom.randInt(Int32(40) ..< 60, [output, input / 16],
            key: MLXRandom.key(seed &+ 1))
        result[stem + ".weight"] = bytes(packed.asType(.uint8), "U8")
        result[stem + ".weight_scale"] = bytes(blocks.asType(.uint8), "F8_E4M3")
        result[stem + ".weight_scale_2"] = scalar(scale, shape: [1])
        result[stem + ".input_scale"] = scalar(0.01, shape: [1])
    }

    private func tensors() throws -> [String: Tensor] {
        let c = Self.configuration()
        var result: [String: Tensor] = [:]
        let outputs = ["mixer.out_proj.weight", "mixer.o_proj.weight",
                       "shared_experts.down_proj.weight"]
        for (name, value) in randomized(try model(), seed: seed) {
            let source = name.replacingOccurrences(of: "image_composition.", with: "")
            let weak = outputs.contains { name.hasSuffix($0) }
            result[source] = bytes(weak ? value * 0.25 : value, "F32")
        }
        let head = "language_model.lm_head"
        let codes = MLXRandom.randInt(Int32(0) ..< 254, [Self.vocabulary, Self.hidden],
            key: MLXRandom.key(seed &+ 99))
        result[head + ".weight"] = bytes(which(codes .>= 127, codes + 1, codes).asType(.uint8), "F8_E4M3")
        result[head + ".input_scale"] = scalar(0.02)
        result[head + ".weight_scale"] = scalar(1.0 / 256)
        let target = "language_model.backbone.layers.2.mixer"
        for (native, raw) in [("fc1", "up_proj"), ("fc2", "down_proj")] {
            result.removeValue(forKey: target + ".switch_mlp." + native + ".weight")
            for expert in 0 ..< c.nRoutedExperts {
                nvfp4(target + ".experts.\(expert)." + raw,
                    input: raw == "up_proj" ? c.moeLatentSize! : c.moeIntermediateSize,
                    output: raw == "up_proj" ? c.moeIntermediateSize : c.moeLatentSize!,
                    seed: seed &+ UInt64(200 + 2 * expert + (raw == "up_proj" ? 0 : 1)) &* 7,
                    scale: 0.0125, into: &result)
            }
        }
        result["vision_model.summary_idxs"] = Tensor(dtype: "I64", shape: [2],
            data: Data(repeating: 0, count: 16))
        try headTensors(into: &result)
        return result
    }

    /// fused = enorm(seed embedding); tiny attention and MoE contributions.
    private func headTensors(into result: inout [String: Tensor]) throws {
        let c = Self.configuration()
        let module = try NemotronSuperMTPModule(configuration: c,
            calibration: .init(keyScale: 1, valueScale: 1), dtype: .float32)
        var dense = Dictionary(uniqueKeysWithValues: randomized(module, seed: seed &+ 5))
        dense["layers.0.eh_proj.weight"] = concatenated(
            [MLXArray.eye(Self.hidden), MLXArray.zeros([Self.hidden, Self.hidden])], axis: 1)
        for name in ["layers.0.enorm.weight", "layers.0.hnorm.weight", "layers.0.norm.weight",
                     "layers.1.norm.weight", "layers.1.final_layernorm.weight"] {
            dense[name] = MLXArray.ones([Self.hidden])
        }
        dense["layers.0.mixer.o_proj.weight"] = dense["layers.0.mixer.o_proj.weight"]! * 0.001
        let prefix = "language_model.mtp."
        for (name, value) in dense where !name.contains(".shared_experts.") && !name.contains(".switch_mlp.") {
            result[prefix + name] = bytes(value, "F32")
        }
        let mixer = prefix + "layers.1.mixer."
        nvfp4(mixer + "shared_experts.up_proj", input: Self.hidden,
            output: c.moeSharedExpertIntermediateSize, seed: seed &+ 900, scale: 1e-4, into: &result)
        nvfp4(mixer + "shared_experts.down_proj", input: c.moeSharedExpertIntermediateSize,
            output: Self.hidden, seed: seed &+ 903, scale: 1e-4, into: &result)
        for expert in 0 ..< c.nRoutedExperts {
            nvfp4(mixer + "experts.\(expert).up_proj", input: c.moeLatentSize!,
                output: c.moeIntermediateSize, seed: seed &+ UInt64(1_000 + 4 * expert),
                scale: 1e-4, into: &result)
            nvfp4(mixer + "experts.\(expert).down_proj", input: c.moeIntermediateSize,
                output: c.moeLatentSize!, seed: seed &+ UInt64(1_002 + 4 * expert),
                scale: 1e-4, into: &result)
        }
        result[prefix + "layers.0.mixer.k_proj.k_scale"] = scalar(1, shape: [1])
        result[prefix + "layers.0.mixer.v_proj.v_scale"] = scalar(1, shape: [1])
    }

    private func withSource<Value>(_ tensors: [String: Tensor],
                                   _ body: (ModelOptCheckpointSource) throws -> Value) throws -> Value {
        var files: [String: ModelOptTensorFile] = [:], map: [String: String] = [:]
        var urls: [URL] = []
        defer { for url in urls { try? FileManager.default.removeItem(at: url) } }
        let keys = tensors.keys.sorted()
        for shard in 0..<2 {
            let name = "fixture-\(shard).safetensors"
            var header: [String: Any] = [:], payload = Data()
            for (i, key) in keys.enumerated() where i % 2 == shard {
                let tensor = tensors[key]!, low = payload.count
                payload.append(tensor.data)
                header[key] = ["dtype": tensor.dtype, "shape": tensor.shape,
                               "data_offsets": [low, payload.count]]
                map[key] = name
            }
            let json = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
            var count = UInt64(json.count).littleEndian
            var data = withUnsafeBytes(of: &count) { Data($0) }
            data.append(json); data.append(payload)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            urls.append(url); try data.write(to: url)
            files[name] = try ModelOptTensorFile(url: url,
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        let index = try JSONSerialization.data(withJSONObject: ["weight_map": map], options: [.sortedKeys])
        let hash = SHA256.hash(data: index).map { String(format: "%02x", $0) }.joined()
        return try body(ModelOptCheckpointSource(indexData: index, indexSHA256: hash, files: files))
    }

    /// The fixture and its head as a `NemotronSuperLocalLoad` staging: the
    /// transaction quotes, claims and loads the head as it does the pinned one.
    func staging() throws -> NemotronSuperLocalLoad.Staging {
        let makeModel = model
        return try withSource(tensors()) { source in
            let head = NemotronSuperLocalLoad.Staging.Head(quote: {
                try NemotronSuperMTPModule.loadQuote(configuration: Self.configuration(), source: source)
            }, load: { installed, quote, construction in
                try NemotronSuperMTPModule.load(for: try #require(installed.model).languageModel,
                    source: source, quote: quote, construction: construction, dtype: .float32)
            })
            return NemotronSuperLocalLoad.Staging(source: source, install: { residency, allowance, construction in
                try NemotronSuperInstallation.stage(source: source, residency: residency, dtype: .float32,
                    backendAllowanceBytes: allowance, construction: construction, makeModel: makeModel)
            }, head: head)
        }
    }

    struct Installation {
        let installed: NemotronSuperInstallation.Installed
        let construction: NativeConstructionScope
        let residency: NemotronSuperResidency
        let head: NemotronSuperMTPModule
        let headQuote: NemotronSuperMTPModule.LoadQuote
    }

    func make() throws -> Installation {
        let scope = NativeConstructionScope()
        let residency = try NemotronSuperResidency(capacityBytes: 32 << 20, maximumRequests: 1)
        return try withSource(tensors()) { source in
            let installed = try NemotronSuperInstallation.stage(source: source, residency: residency,
                dtype: .float32, backendAllowanceBytes: 1 << 20, construction: scope, makeModel: model)
            let language = try #require(installed.model).languageModel
            let quote = try NemotronSuperMTPModule.loadQuote(configuration: language.configuration,
                source: source)
            let head = try NemotronSuperMTPModule.load(for: language, source: source, quote: quote,
                construction: scope, dtype: .float32)
            return Installation(installed: installed, construction: scope, residency: residency,
                head: head, headQuote: quote)
        }
    }
}
