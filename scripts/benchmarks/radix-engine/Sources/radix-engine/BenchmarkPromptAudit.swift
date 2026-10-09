import Foundation
import CryptoKit
import MLXLMCommon
#if RADIX_CANDIDATE
@_spi(Benchmarking) import ProviderCore
import ProviderCoreFoundation

/// Uses the native tokenizer/normalizer without constructing a model, loading
/// weights, binding a Metal library, or evaluating an MLX array.
enum BenchmarkPromptAudit {
    /// The same environment selects the engine policy and validates its inputs.
    /// This pure check requires a verified boundary inside the actual prompt.
    static func requireInstructionPrefixCoverage(
        _ inputs: [Input], modelType: String?, environment: [String: String]
    ) throws {
        guard environment["DARKBLOOM_CBV2_SELECTIVE_KV"] == "instruction-half" else { return }
        let limit = EngineV2Factory.instructionProtectedPrefixTokens
        guard modelType == "gpt_oss", !inputs.isEmpty, inputs.allSatisfy({ input in
            guard let prefix = input.instructionPrefixTokens else { return false }
            return (1...limit).contains(prefix) && prefix <= input.tokens.count
        }) else {
            throw RadixBenchmark.Failure.message(
                "instruction-half input has an unverified header or exceeds the protected \(limit)-token prefix")
        }
    }

    static func run(options: BenchmarkOptions, report: HTTPReport, inputSHA256: String) async throws {
        let directory = options.modelDirectory
        let config = try JSONSerialization.jsonObject(with:
            Data(contentsOf: directory.appendingPathComponent("config.json"))) as? [String: Any]
        let modelType = config?["model_type"] as? String
        let tokenizer = try await LocalTokenizerLoader().load(from: directory)
        let date = PromptRenderDate.capture()
        let rows = try report.rows.map { row -> [String: Any] in
            let prompt = try EngineV2Factory.benchmarkPrompt(
                body: JSONEncoder().encode(row.request.body), tokenizer: tokenizer,
                modelType: modelType, defaultDate: date)
            let prefix = prompt.instructionPrefixTokens
            return ["id": row.case.id, "prompt_token_ids": prompt.tokens,
                    "instruction_prefix_tokens": prefix as Any? ?? NSNull(),
                    "instruction_prefix_text": prefix.map {
                        tokenizer.decode(tokenIds: Array(prompt.tokens.prefix($0)))
                    } as Any? ?? NSNull(),
                    "first_128_tokens": tokenizer.decode(tokenIds: Array(prompt.tokens.prefix(128))),
                    "first_256_tokens": tokenizer.decode(tokenIds: Array(prompt.tokens.prefix(256))),
                    "render_date": prompt.renderDate]
        }
        let metadataNames = ["config.json", "tokenizer.json", "tokenizer_config.json", "chat_template.jinja"]
        var metadataHashes: [String: String] = [:]
        for name in metadataNames {
            let url = directory.appendingPathComponent(name)
            if let bytes = try? Data(contentsOf: url) {
                metadataHashes[name] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            }
        }
        let result: [String: Any] = ["scope": "native_prompt_metadata_only", "status": "observed",
            "input_sha256": inputSHA256, "runtime_identity": EngineV2Factory.benchmarkRuntimeIdentity(),
            "model_metadata_sha256": metadataHashes, "rows": rows,
            "model_weights_loaded": false, "mlx_arrays_evaluated": false]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: options.outputURL, options: .atomic)
    }
}
#endif
