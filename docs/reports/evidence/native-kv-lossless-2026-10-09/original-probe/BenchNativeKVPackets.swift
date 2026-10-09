import CryptoKit
import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Research extraction of bounded public synthetic native cache states.
public enum BenchNativeKVPackets {
    public static func run() async {
        do {
            let args = CommandLine.arguments
            guard args.count == 4 else {
                throw MLXError.caught(
                    "usage: BenchNativeKVPackets MODEL OUTPUT MODEL_AGGREGATE_HASH")
            }
            let modelDirectory = URL(fileURLWithPath: args[1])
            let outputDirectory = URL(fileURLWithPath: args[2])
            let configData = try Data(
                contentsOf: modelDirectory.appendingPathComponent("config.json"))
            let config = try JSONSerialization.jsonObject(with: configData) as! [String: Any]
            let modelType = config["model_type"] as? String ?? ""
            guard ["gemma4", "gemma4_text", "gpt_oss"].contains(modelType) else {
                throw MLXError.caught("unsupported model; MiMo is excluded")
            }
            let aggregateHash = args[3]
            guard aggregateHash.count == 64, aggregateHash.allSatisfy({ $0.isHexDigit }) else {
                throw MLXError.caught("require verified model aggregate")
            }
            try FileManager.default.createDirectory(
                at: outputDirectory, withIntermediateDirectories: true)
            let container = try await LLMModelFactory.shared.loadContainer(
                from: modelDirectory, using: #huggingFaceTokenizerLoader())
            try await container.perform { (context: ModelContext) async throws in
                let capturedConfig =
                    try JSONSerialization.jsonObject(with: configData) as! [String: Any]
                guard let hooks = v2Hooks(for: context.model) else {
                    throw MLXError.caught("missing actual model cache hooks")
                }
                let nativeProbe = hooks.model(MLXArray([Int32(0)]).reshaped(1, 1), cache: nil)
                let vocabulary = nativeProbe.dim(-1)
                let initialTokens = syntheticPrompt(length: 32, seed: 0xFACE, vocabSize: vocabulary)
                let caches = try hooks.buildCaches { index, kind in
                    let rows: [CBv2SequenceKV]
                    if kind.sharesKVWithLayer != nil {
                        rows = []
                    } else {
                        switch kind.attention {
                        case .full:
                            rows = [
                                CBv2FullSequenceKV(
                                    promptLength: 32, maxLength: 64, kvHeads: kind.kvHeads,
                                    headDim: kind.headDim, valueHeadDim: kind.valueHeadDim)
                            ]
                        case .slidingWindow(let window):
                            rows = [
                                CBv2WindowedSequenceKV(
                                    window: window, kvHeads: kind.kvHeads, headDim: kind.headDim,
                                    valueHeadDim: kind.valueHeadDim)
                            ]
                        }
                    }
                    return CBv2LayerCache(layerIndex: index, kind: kind, rows: rows)
                }
                let adapter = CBv2SteppableLanguageModelAdapter(hooks.model)
                let globalOwners = hooks.layerKinds.enumerated().compactMap { index, kind in
                    kind.attention == .full && kind.sharesKVWithLayer == nil ? index : nil
                }
                let isGemma = modelType.hasPrefix("gemma4")
                guard !isGemma || globalOwners.count == 5 else {
                    throw MLXError.caught("require all five Gemma global owners")
                }
                let selected = isGemma ? [0] + globalOwners : [0, 1]
                let parameters = hooks.model.parameters().flattened()
                var records: [[String: Any]] = []
                var copiedBytes = 0
                var consumedTokens = initialTokens
                func digest(_ data: Data) -> String {
                    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                }
                func save(
                    _ array: MLXArray, name: String, role: String, layer: Int, phase: String,
                    position: Int
                ) throws {
                    guard array.nbytes <= 1 << 20, copiedBytes <= (4 << 20) - array.nbytes else {
                        throw MLXError.caught("4MiB total packet bound exceeded")
                    }
                    let data = array.asData(access: .copy).data
                    guard data.count == array.nbytes else {
                        throw MLXError.caught("native packet extent mismatch")
                    }
                    try data.write(to: outputDirectory.appendingPathComponent(name))
                    copiedBytes += data.count
                    records.append([
                        "file": name, "role": role, "layer": layer, "phase": phase,
                        "position": position, "shape": array.shape,
                        "dtype": String(describing: array.dtype),
                        "bytes": data.count, "sha256": digest(data),
                    ])
                }
                var relationChecks: [[String: Any]] = []
                var tokens = MLXArray(initialTokens.map(Int32.init)).reshaped(1, 32)
                for phase in ["prefill", "decode"] {
                    let logits = adapter.forward(tokens: tokens, caches: caches)
                    eval(logits)
                    for layer in selected {
                        guard let cache = caches[layer] as? CBv2LayerCache, cache.rows.count == 1
                        else { throw MLXError.caught("require actual owned native row") }
                        let snapshot = cache.rows[0].snapshot()
                        try save(
                            snapshot.keys, name: "\(phase)-L\(layer)-K.bin", role: "keys",
                            layer: layer, phase: phase, position: snapshot.offset)
                        try save(
                            snapshot.values, name: "\(phase)-L\(layer)-V.bin", role: "values",
                            layer: layer, phase: phase, position: snapshot.offset)
                        if isGemma && globalOwners.contains(layer) {
                            let suffix = "layers.\(layer).self_attn.k_norm.weight"
                            let matching = parameters.filter { $0.0.hasSuffix(suffix) }
                            guard matching.count == 1 else {
                                throw MLXError.caught("missing unique loaded Gamma \(suffix)")
                            }
                            let (gammaName, gamma) = matching[0]
                            guard gamma.shape == [512], snapshot.keys.dim(-1) == 512 else {
                                throw MLXError.caught("unexpected global head shape")
                            }
                            let dtypeMatch =
                                gamma.dtype == snapshot.values.dtype
                                && snapshot.keys.dtype == snapshot.values.dtype
                            var bitIdentity = false
                            if dtypeMatch {
                                let derived = snapshot.values * gamma
                                let columns = MLXArray(
                                    (Array(64 ..< 256) + Array(320 ..< 512)).map(Int32.init))
                                let nativeBands = take(snapshot.keys, columns, axis: -1)
                                let derivedBands = take(derived, columns, axis: -1)
                                let bits: DType = snapshot.keys.dtype.size == 4 ? .uint32 : .uint16
                                bitIdentity = arrayEqual(
                                    nativeBands.view(dtype: bits), derivedBands.view(dtype: bits)
                                ).item(Bool.self)
                            }
                            let gammaData = gamma.asData(access: .copy).data
                            relationChecks.append([
                                "layer": layer, "phase": phase, "position": snapshot.offset,
                                "gamma_name": gammaName, "gamma_sha256": digest(gammaData),
                                "gamma_dtype": String(describing: gamma.dtype),
                                "keys_dtype": String(describing: snapshot.keys.dtype),
                                "values_dtype": String(describing: snapshot.values.dtype),
                                "dtype_match": dtypeMatch,
                                "unrotated_native_bit_identity": bitIdentity,
                                "retained_rotated_bands": [[0, 64], [256, 320]],
                                "unrotated_columns": 384,
                            ])
                            if phase == "prefill" {
                                try save(
                                    gamma, name: "L\(layer)-Gamma.bin", role: "gamma", layer: layer,
                                    phase: phase, position: snapshot.offset)
                            }
                        }
                    }
                    let next = argMax(logits[0, -1], axis: -1).item(Int32.self)
                    consumedTokens.append(Int(next))
                    tokens = MLXArray([next]).reshaped(1, 1)
                }
                let receipt: [String: Any] = [
                    "model_type": modelType, "model_path": modelDirectory.path,
                    "model_aggregate_sha256": aggregateHash, "config_sha256": digest(configData),
                    "sdk_revision": buildRevision(),
                    "input_seed": "FACE", "prefill_token_ids": initialTokens,
                    "consumed_token_ids": Array(consumedTokens.prefix(33)),
                    "positions": [32, 33], "copied_native_payload_bytes": copiedBytes,
                    "host_payload_bound_bytes": 4 << 20,
                    "records": records, "relations": relationChecks, "config": capturedConfig,
                    "claim":
                        "actual native raw-basis states only; no storage omission or INT4 composition",
                ]
                try JSONSerialization.data(
                    withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]
                ).write(to: outputDirectory.appendingPathComponent("receipt.json"))
                print(
                    "copied \(copiedBytes) native bytes; \(relationChecks.count) global relation checks"
                )
            }
        } catch {
            print("native packet probe failed: \(error)")
            exit(1)
        }
    }
}
