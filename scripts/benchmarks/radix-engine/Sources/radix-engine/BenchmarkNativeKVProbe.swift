#if RADIX_CANDIDATE
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import ProviderCoreFoundation
@_spi(Benchmarking) import ProviderCore

/// A short target-only load diagnostic. It constructs no serving engine or
/// cache store, and makes no inference-throughput or paged-serving claim.
enum BenchmarkNativeKVProbe {
    static func run(options: BenchmarkOptions, modelID: String) async throws {
        guard !options.cacheEnabled, !options.mtpEnabled, options.concurrency == 1 else {
            throw RadixBenchmark.Failure.message(
                "native KV inspection requires cache-off, mtp-off and concurrency 1")
        }
        guard let metallibHash = bindRuntimeMetallibForMLX() else {
            throw RadixBenchmark.Failure.message("normal immutable metallib binding failed")
        }
        let directory = options.modelDirectory
        var report: [String: Any] = [
            "schema": 1, "mode": "native_kv_type_probe", "model": modelID,
            "model_directory": directory.path, "metallib_hash": metallibHash,
            "scope": "Actual serving target and newCacheV2; two-token prefill and one-token decode. No serving backend, SSD store or MTP assistant is constructed.",
            "probe_token_id": 0, "prefill_tokens": 2, "decode_tokens": 1,
            "memory_active_before_load": Memory.activeMemory,
        ]
        do {
            guard let beforeHash = WeightHasher.computeHash(
                snapshotDir: directory, modelID: modelID) else {
                throw RadixBenchmark.Failure.message("model hash unavailable before load")
            }
            report["model_hash_before_load"] = beforeHash
            report["prompt_contract_id"] = try PromptContractIdentity.compute(modelDirectory: directory)
            let config = try JSONSerialization.jsonObject(with: Data(contentsOf:
                directory.appendingPathComponent("config.json"))) as? [String: Any]
            let isVLM = config?["vision_config"] is [String: Any]
            report["model_type"] = config?["model_type"]
            report["is_vlm"] = isVLM
            let container: ModelContainer
            if isVLM {
                container = try await VLMModelFactory.shared.loadContainer(
                    from: directory, using: LocalTokenizerLoader())
            } else {
                container = try await LLMModelFactory.shared.loadContainer(
                    from: directory, using: LocalTokenizerLoader())
            }
            guard let afterHash = WeightHasher.computeHash(
                snapshotDir: directory, modelID: modelID), afterHash == beforeHash else {
                throw RadixBenchmark.Failure.message("model hash changed around load")
            }
            report["model_hash_after_load"] = afterHash
            report["memory_active_after_load"] = Memory.activeMemory
            let started = DispatchTime.now().uptimeNanoseconds
            let result = try await container.perform { context in
                let target = try EngineV2Factory.benchmarkServingModel(
                    model: context.model, isVLM: isVLM, modelDirectory: directory)
                return try EngineV2Factory.inspectNativeKVTypes(model: target)
            }
            report["probe_seconds"] = RadixBenchmark.seconds(
                DispatchTime.now().uptimeNanoseconds - started)
            report["layer_dtypes"] = result.layerDTypes.map { String(describing: $0) }
            report["observations"] = result.observations.map { observation -> [String: Any] in
                ["storage_index": observation.storageIndex,
                 "model_layer_index": observation.modelLayerIndex,
                 "phase": observation.phase.rawValue,
                 "keys_dtype": String(describing: observation.keysDType),
                 "values_dtype": String(describing: observation.valuesDType),
                 "keys_shape": observation.keysShape,
                 "values_shape": observation.valuesShape]
            }
            report["memory_active_after_probe"] = Memory.activeMemory
            report["memory_cache_after_probe"] = Memory.cacheMemory
            report["status"] = "passed"
            try write(report, to: options.outputURL)
        } catch {
            report["status"] = "failed"
            report["error"] = String(describing: error)
            report["memory_active_after_failure"] = Memory.activeMemory
            try write(report, to: options.outputURL)
            throw error
        }
    }

    private static func write(_ report: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
#endif
