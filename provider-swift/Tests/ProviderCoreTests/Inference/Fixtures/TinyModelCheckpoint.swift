import Foundation
import MLX
import MLXLLM
import MLXNN
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

/// The tests that load the tiny model. They change the model cache folder
/// (`ModelScanner.configureCacheDirectory`). That setting is process-wide,
/// so they run one at a time. `.serialized` also applies to the suites
/// nested in this one. It does not stop other suites from running at the
/// same time, so the test run needs `--no-parallel`. CI and
/// `make provider-test` use it (`scripts/run-provider-tests.sh`).
@Suite("Tiny model load through the real loader", .serialized)
enum TinyModelLoadTests {}

/// A tiny GPT-OSS checkpoint that a test makes in a temp folder.
///
/// The real loader reads it like any downloaded model: `config.json`,
/// `model.safetensors`, `tokenizer.json` and `tokenizer_config.json` in a
/// Hugging Face cache folder (`models--org--name/snapshots/<revision>`).
/// The weights are seeded random values, so no test downloads or reads real
/// weights. Nothing is written outside the temp folder.
///
/// The model has 2 layers, a hidden size of 64 and 272 vocabulary entries,
/// so the weights are about 0.5 MB. The tokenizer is a byte-level BPE
/// tokenizer: token id N is byte N, and id 256 is the end token.
struct TinyModelCheckpoint {
    static let modelType = "gpt_oss"
    private static let endTokenID = 256
    private static let endToken = "<|endoftext|>"
    static let maxContextLength = 2048

    let modelID: String
    let root: URL
    /// The model cache folder. Give it to `withModelCache`.
    let cacheDirectory: URL
    /// The sum of the bytes of all saved weight arrays.
    let weightBytes: Int

    init(seed: UInt64 = 7) throws {
        modelID = "darkbloom-test/tiny-gpt-oss-\(UUID().uuidString.lowercased())"
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiny-model-\(UUID().uuidString)", isDirectory: true)
        cacheDirectory = root.appendingPathComponent("hub", isDirectory: true)
        let modelFolder = cacheDirectory.appendingPathComponent(
            "models--" + modelID.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
        let revision = "tiny-\(seed)"
        let snapshot = modelFolder.appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)
        let refs = modelFolder.appendingPathComponent("refs", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
        try Data(revision.utf8).write(to: refs.appendingPathComponent("main"))

        let config = Self.config
        try Self.writeJSON(config, to: snapshot.appendingPathComponent("config.json"))
        try Self.writeJSON(Self.tokenizerData, to: snapshot.appendingPathComponent("tokenizer.json"))
        try Self.writeJSON(Self.tokenizerConfig, to: snapshot.appendingPathComponent("tokenizer_config.json"))
        weightBytes = try Self.writeWeights(
            config: config, seed: seed, to: snapshot.appendingPathComponent("model.safetensors"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// The snapshot folder as the provider resolves it. Call it inside
    /// `withModelCache`.
    func resolvedSnapshot() throws -> URL {
        try #require(ModelScanner.resolveLocalPath(modelID: modelID))
    }

    /// The model as the provider's own scanner describes it. Call it inside
    /// `withModelCache`.
    func scannedModelInfo() throws -> ModelInfo {
        try #require(ModelScanner.parseModelInfo(snapshotDir: try resolvedSnapshot(), modelName: modelID))
    }

    /// Run `body` with the provider's model cache set to this checkpoint's
    /// cache folder, then put the earlier value back.
    func withModelCache<T>(_ body: () async throws -> T) async rethrows -> T {
        let previous = ModelScanner.configuredCacheDirectory
        ModelScanner.configureCacheDirectory(cacheDirectory.path)
        defer { ModelScanner.configureCacheDirectory(previous) }
        return try await body()
    }

    // MARK: - Files

    private static var config: [String: Any] {
        [
            "model_type": modelType,
            "architectures": ["GptOssForCausalLM"],
            "num_hidden_layers": 2,
            "num_local_experts": 4,
            "num_experts_per_tok": 2,
            "vocab_size": 272,
            "rms_norm_eps": 1e-5,
            "hidden_size": 64,
            "intermediate_size": 64,
            "head_dim": 64,
            "num_attention_heads": 4,
            "num_key_value_heads": 2,
            "sliding_window": 32,
            "layer_types": ["sliding_attention", "full_attention"],
            "max_position_embeddings": maxContextLength,
            "eos_token_id": endTokenID,
        ]
    }

    private static var tokenizerConfig: [String: Any] {
        [
            "tokenizer_class": "GPT2TokenizerFast",
            "eos_token": endToken,
            "model_max_length": maxContextLength,
            "clean_up_tokenization_spaces": false,
        ]
    }

    /// GPT-2 byte-level BPE with one token per byte and no merges.
    private static var tokenizerData: [String: Any] {
        var vocab: [String: Int] = [:]
        for (byte, character) in byteCharacters.enumerated() {
            vocab[String(character)] = byte
        }
        let byteLevel: [String: Any] = [
            "type": "ByteLevel", "add_prefix_space": false, "trim_offsets": true, "use_regex": true,
        ]
        return [
            "version": "1.0",
            "added_tokens": [[
                "id": endTokenID, "content": endToken, "single_word": false, "lstrip": false,
                "rstrip": false, "normalized": false, "special": true,
            ]],
            "pre_tokenizer": byteLevel,
            "decoder": byteLevel,
            "model": [
                "type": "BPE", "fuse_unk": false, "byte_fallback": false,
                "vocab": vocab, "merges": [String](),
            ] as [String: Any],
        ]
    }

    /// The GPT-2 map from each byte to a printable character.
    private static var byteCharacters: [Character] {
        let printable = Array(33...126) + Array(161...172) + Array(174...255)
        var extra = 0
        return (0..<256).map { byte in
            if printable.contains(byte) {
                return Character(Unicode.Scalar(UInt8(byte)))
            }
            defer { extra += 1 }
            return Character(Unicode.Scalar(UInt32(256 + extra))!)
        }
    }

    private static func writeJSON(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url)
    }

    /// Build the model from `config`, give every parameter a seeded random
    /// value, and save the parameters in bfloat16, like a real checkpoint.
    /// Returns the bytes saved.
    private static func writeWeights(config: [String: Any], seed: UInt64, to url: URL) throws -> Int {
        let configuration = try JSONDecoder().decode(
            GPTOSSConfiguration.self, from: JSONSerialization.data(withJSONObject: config))
        let model = GPTOSSModel(configuration)
        let parameters = model.parameters().flattened().sorted { $0.0 < $1.0 }
        var arrays: [String: MLXArray] = [:]
        for (index, (name, value)) in parameters.enumerated() {
            let key = MLXRandom.key(seed &* 1_000_003 &+ UInt64(index))
            let noise = MLXRandom.normal(value.shape, key: key)
            let random: MLXArray
            if value.ndim <= 1 {
                // Norm scales stay near 1. Biases and attention sinks stay near 0.
                random = name.hasSuffix("norm.weight") ? 1 + 0.1 * noise : 0.1 * noise
            } else {
                random = noise * (1 / Float(value.dim(-1)).squareRoot())
            }
            arrays[name] = random.asType(.bfloat16)
        }
        eval(Array(arrays.values))
        // Keep the metadata a string map: the writer emits null for an empty one.
        try MLX.save(arrays: arrays, metadata: ["format": "mlx"], url: url)
        return arrays.values.reduce(0) { $0 + $1.nbytes }
    }
}
