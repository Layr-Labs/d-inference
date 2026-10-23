import CryptoKit
import Foundation
import MLX
import MLXNN
import Testing
@testable import MLXLLM
@testable import MLXLMCommon
@testable import MLXVLM
@testable import ProviderCore

struct SuperInstalledFixture {
    var radioDimensions: NemotronRadioDimensions? = nil
    private struct Tensor { let dtype: String; let shape: [Int]; let data: Data }
    /// 64-wide attention heads, the narrowest the paged KV kernels take; the
    /// Super owner serves paged KV only.
    private func model() throws -> NemotronSuperModel {
        let language = NemotronHModel(NemotronHConfiguration(vocabSize: 32, hiddenSize: 16,
            numHiddenLayers: 3, numAttentionHeads: 1, numKeyValueHeads: 1,
            mambaNumHeads: 1, mambaHeadDim: 16, ssmStateSize: 4, convKernel: 4, nGroups: 1,
            intermediateSize: 16, moeIntermediateSize: 16, moeSharedExpertIntermediateSize: 16,
            nRoutedExperts: 2, numExpertsPerTok: 1, hybridOverridePattern: "M*E", headDim: 64))
        let tower = NemotronRadio(radioDimensions ?? NemotronRadioDimensions(width: 2, layers: 1, heads: 1,
            channels: 1, patch: 2, positionSide: 2, prefix: 1, mlpWidth: 3))
        let images = NemotronSuperImageComposition(tower: tower,
            projector: NemotronSuperVisionProjector(visionWidth: 2, hiddenWidth: 3, outputWidth: 16),
            width: 16, imageTokenID: 18)
        return try NemotronSuperModel(languageModel: language, imageComposition: images)
    }
    private func scalar(_ value: Float) -> Tensor {
        var bits = value.bitPattern.littleEndian
        return Tensor(dtype: "F32", shape: [], data: withUnsafeBytes(of: &bits) { Data($0) })
    }
    private func tensors() throws -> [String: Tensor] {
        let candidate = try model()
        var result: [String: Tensor] = [:]
        for (name, value) in candidate.parameters().flattened() {
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
                let p = root + ".experts.\(expert)." + raw
                result[p + ".weight"] = Tensor(dtype: "U8", shape: [16, 8], data: Data(repeating: 0, count: 128))
                result[p + ".weight_scale"] = Tensor(dtype: "F8_E4M3", shape: [16, 1], data: Data(repeating: 56, count: 16))
                result[p + ".weight_scale_2"] = scalar(1)
                result[p + ".input_scale"] = scalar(1)
            }
        }
        // Retained MTP is accounted separately; it is never executed or dropped invisibly.
        result["language_model.mtp.fixture.weight"] = scalar(1)
        result["vision_model.summary_idxs"] = Tensor(dtype: "I64", shape: [2], data: Data(repeating: 0, count: 16))
        return result
    }
    private func withSource(_ tensors: [String: Tensor], _ body: (ModelOptCheckpointSource) throws -> Void) throws {
        var files: [String: ModelOptTensorFile] = [:], map: [String: String] = [:]
        var urls: [URL] = []
        defer { for url in urls { try? FileManager.default.removeItem(at: url) } }
        // Split consecutive tensor/scale keys across shards, deliberately.
        let keys = tensors.keys.sorted()
        for shard in 0..<2 {
            let name = "fixture-\(shard).safetensors"
            var header: [String: Any] = [:], bytes = Data()
            for (i, key) in keys.enumerated() where i % 2 == shard {
                let tensor = tensors[key]!, low = bytes.count
                bytes.append(tensor.data)
                header[key] = ["dtype": tensor.dtype, "shape": tensor.shape, "data_offsets": [low, bytes.count]]
                map[key] = name
            }
            let json = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
            var count = UInt64(json.count).littleEndian
            var data = withUnsafeBytes(of: &count) { Data($0) }
            data.append(json); data.append(bytes)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            urls.append(url); try data.write(to: url)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            files[name] = try ModelOptTensorFile(url: url, sha256: hash)
        }
        let index = try JSONSerialization.data(withJSONObject: ["weight_map": map], options: [.sortedKeys])
        let hash = SHA256.hash(data: index).map { String(format: "%02x", $0) }.joined()
        try body(ModelOptCheckpointSource(indexData: index, indexSHA256: hash, files: files))
    }

    /// The same fixture as a `NemotronSuperLocalLoad` staging, so it installs
    /// through the transaction's real claim, fences and builder. The shard
    /// files are unlinked at once; their open descriptors stay readable.
    func staging() throws -> NemotronSuperLocalLoad.Staging {
        let makeModel = model
        return try withSourceValue(tensors()) { source in
            NemotronSuperLocalLoad.Staging(source: source, install: { residency, allowance, construction in
                try NemotronSuperInstallation.stage(source: source, residency: residency, dtype: .float32,
                    backendAllowanceBytes: allowance, construction: construction, makeModel: makeModel)
            }, head: nil)
        }
    }

    private func withSourceValue<Value>(_ tensors: [String: Tensor],
                                        _ body: (ModelOptCheckpointSource) throws -> Value) throws -> Value {
        var value: Value?
        try withSource(tensors) { value = try body($0) }
        return try #require(value)
    }

    func make() throws -> (NemotronSuperInstallation.Installed, NativeConstructionScope, NemotronSuperResidency) {
        let scope = NativeConstructionScope()
        let residency = try NemotronSuperResidency(capacityBytes: 16 << 20, maximumRequests: 1)
        var installed: NemotronSuperInstallation.Installed?
        try withSource(tensors()) { source in
            installed = try NemotronSuperInstallation.stage(source: source, residency: residency,
                dtype: .float32, backendAllowanceBytes: 1 << 20, construction: scope, makeModel: model)
        }
        return (try #require(installed), scope, residency)
    }
}
