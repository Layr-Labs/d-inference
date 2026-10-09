import CryptoKit
import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

public enum BenchWindowLifetime {
    public static func run() async {
        do {
            let args = CommandLine.arguments
            guard args.count == 4, let steps = Int(args[2]), [32, 64].contains(steps) else {
                throw MLXError.caught("usage: BenchWindowLifetime MODEL STEPS OUTPUT.json")
            }
            let directory = URL(fileURLWithPath: args[1])
            let configData = try Data(contentsOf: directory.appendingPathComponent("config.json"))
            let config = try JSONSerialization.jsonObject(with: configData) as! [String: Any]
            guard
                ["gemma4", "gemma4_text", "gpt_oss"].contains(config["model_type"] as? String ?? "")
            else {
                throw MLXError.caught("qualified families only; MiMo excluded")
            }
            let container = try await LLMModelFactory.shared.loadContainer(
                from: directory, using: #huggingFaceTokenizerLoader())
            try await container.perform { (context: ModelContext) async throws in
                guard let hooks = v2Hooks(for: context.model) else {
                    throw MLXError.caught("missing loaded native hooks")
                }
                let vocabulary = hooks.model(MLXArray([Int32(0)]).reshaped(1, 1), cache: nil).dim(
                    -1)
                let prompt = syntheticPrompt(length: 512, seed: 0xFACE, vocabSize: vocabulary)
                func caches(_ hinted: Bool) throws -> [CBv2AttendingLayerCache] {
                    try hooks.buildCaches { index, kind in
                        let rows: [CBv2SequenceKV]
                        if kind.sharesKVWithLayer != nil {
                            rows = []
                        } else {
                            switch kind.attention {
                            case .full:
                                rows = [
                                    CBv2FullSequenceKV(
                                        promptLength: 512, maxLength: 512 + steps,
                                        kvHeads: kind.kvHeads, headDim: kind.headDim,
                                        valueHeadDim: kind.valueHeadDim)
                                ]
                            case .slidingWindow(let window):
                                rows = [
                                    CBv2WindowedSequenceKV(
                                        window: window, kvHeads: kind.kvHeads,
                                        headDim: kind.headDim, valueHeadDim: kind.valueHeadDim,
                                        elasticStorage: true,
                                        maximumSequenceLength: hinted ? 512 + steps : nil)
                                ]
                            }
                        }
                        return CBv2LayerCache(layerIndex: index, kind: kind, rows: rows)
                    }
                }
                let parent = try caches(false)
                let hinted = try caches(true)
                let model = CBv2SteppableLanguageModelAdapter(hooks.model)
                var input = MLXArray(prompt.map(Int32.init)).reshaped(1, 512)
                var tokens: [Int] = []
                var logitsEqual = true
                var finishReason = "length"
                let stopTokens = context.configuration.eosTokenIds
                for _ in 0 ..< steps {
                    let expected = model.forward(tokens: input, caches: parent)
                    let actual = model.forward(tokens: input, caches: hinted)
                    eval(expected, actual)
                    let bitType: DType = expected.dtype.size == 4 ? .uint32 : .uint16
                    logitsEqual =
                        logitsEqual && expected.dtype == actual.dtype
                        && arrayEqual(expected.view(dtype: bitType), actual.view(dtype: bitType))
                            .item(Bool.self)
                    let next = argMax(expected[0, -1], axis: -1).item(Int32.self)
                    let actualNext = argMax(actual[0, -1], axis: -1).item(Int32.self)
                    guard next == actualNext else {
                        throw MLXError.caught("generated token diverged")
                    }
                    tokens.append(Int(next))
                    if stopTokens.contains(Int(next)) {
                        finishReason = "eos"
                        break
                    }
                    input = MLXArray([next]).reshaped(1, 1)
                }
                var snapshotsEqual = true
                var slidingReceipts: [[String: Any]] = []
                for (layer, kind) in hooks.layerKinds.enumerated()
                where kind.sharesKVWithLayer == nil {
                    guard let a = parent[layer] as? CBv2LayerCache,
                        let b = hinted[layer] as? CBv2LayerCache
                    else {
                        throw MLXError.caught("require actual owning caches")
                    }
                    let x = a.rows[0].snapshot()
                    let y = b.rows[0].snapshot()
                    let bits: DType = x.keys.dtype.size == 4 ? .uint32 : .uint16
                    snapshotsEqual =
                        snapshotsEqual && x.offset == y.offset
                        && arrayEqual(x.keys.view(dtype: bits), y.keys.view(dtype: bits)).item(
                            Bool.self)
                        && arrayEqual(x.values.view(dtype: bits), y.values.view(dtype: bits)).item(
                            Bool.self)
                    if case .slidingWindow(let window) = kind.attention {
                        let old = a.rows[0]
                        let new = b.rows[0]
                        let bytesPerSlot =
                            kind.kvHeads * (kind.headDim + kind.valueHeadDim) * y.keys.dtype.size
                        slidingReceipts.append([
                            "layer": layer, "semantic_window": window,
                            "parent_capacity": old.byteCount / bytesPerSlot,
                            "hint_capacity": new.byteCount / bytesPerSlot,
                            "parent_tensor_bytes": old.byteCount,
                            "hint_tensor_bytes": new.byteCount,
                            "dtype": String(describing: y.keys.dtype), "absolute_offset": y.offset,
                        ])
                    }
                }
                guard logitsEqual, snapshotsEqual else {
                    throw MLXError.caught("native storage/logit bits diverged")
                }
                let receipt: [String: Any] = [
                    "model_path": directory.path, "sdk_revision": buildRevision(),
                    "config_sha256": SHA256.hash(data: configData).map {
                        String(format: "%02x", $0)
                    }.joined(),
                    "prompt_token_ids": prompt, "generated_token_ids": tokens,
                    "generated_tokens": tokens.count, "maximum_completion_tokens": steps,
                    "finish_reason": finishReason,
                    "native_logit_bits_equal": logitsEqual,
                    "native_snapshot_bits_equal": snapshotsEqual,
                    "sliding_rows": slidingReceipts,
                    "claim":
                        "same native math; declared horizon only bounds geometric slack; no TPS or admission credit claim",
                ]
                try JSONSerialization.data(
                    withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted]
                )
                .write(to: URL(fileURLWithPath: args[3]))
                print("matched \(tokens.count) generated tokens (\(finishReason)) and all native cache/logit bits")
            }
        } catch {
            print("window lifetime control failed: \(error)")
            exit(1)
        }
    }
}
