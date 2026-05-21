import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
#if canImport(os)
import os
#endif

// MARK: - ClusterModelLoader
//
// Loads a `LlamaModelTP` (fp16 tensor-parallel) from a local model checkpoint
// directory. A dedicated loader is needed because the standard `LLMModelFactory`
// pipeline is wired to produce `LlamaModel` (single-rank) via the model-type
// registry in `LLMModelFactory.swift`. `LlamaModelTP` takes an `MLX.DistributedGroup`
// at construction time, which the factory doesn't thread through — that coupling
// means we can't easily reuse `LLMModelFactory._load` without making it
// DistributedGroup-aware across the library boundary.
//
// After `DistributedGroupBootstrap.bootstrap()` completes it sets `MLX_RANK`,
// `MLX_JACCL_COORDINATOR`, and `MLX_IBV_DEVICES` in the process environment.
// `MLX.DistributedGroup()` reads those env vars at construction time, so calling
// it here (after bootstrap) yields the correct group for the jaccl backend.
// The ProviderCore.DistributedGroup is not passed through — we use MLX's own init.
//
// This loader:
//   1. Reads `config.json` from the model directory and decodes a `LlamaConfiguration`.
//   2. Calls `MLX.DistributedGroup()` to get the active group (env vars set by bootstrap).
//   3. Constructs `LlamaModelTP(config, group: group)`.
//   4. Calls `loadWeights(modelDirectory:model:)` (from MLXLMCommon) which
//      enumerates .safetensors files, calls `model.sanitize(weights:)` (which
//      slices per-rank shards for `world > 1`), and applies the weights.
//   5. Returns the loaded model.
//
// The tokenizer is loaded separately via `LocalTokenizerLoader` using the
// standard directory-scan path.

public enum ClusterModelLoaderError: Error, CustomStringConvertible, Sendable {
    case configNotFound(URL)
    case configDecodeFailed(String)
    case modelConstructionFailed(String)
    case weightLoadFailed(String)

    public var description: String {
        switch self {
        case .configNotFound(let url):
            return "config.json not found at \(url.path)"
        case .configDecodeFailed(let msg):
            return "Failed to decode LlamaConfiguration: \(msg)"
        case .modelConstructionFailed(let msg):
            return "Failed to construct LlamaModelTP: \(msg)"
        case .weightLoadFailed(let msg):
            return "Failed to load weights into LlamaModelTP: \(msg)"
        }
    }
}

public enum ClusterModelLoader {

    private static let logger = Logger(
        subsystem: "io.darkbloom.provider", category: "ClusterModelLoader")

    /// HF config.json fields we read directly to recover the real hidden /
    /// layer / vocab dimensions. We can't read these off `LlamaConfiguration`
    /// because its stored properties are `internal` to MLXLLM (cross-module
    /// access denied), so we parse a small mirror struct from the same JSON.
    private struct ConfigMetadata: Decodable {
        let hidden_size: Int
        let num_hidden_layers: Int
        let vocab_size: Int
    }

    /// Parse just the hidden / layer / vocab dimensions from a model directory's
    /// config.json. Used by both the PP and TP load paths so the result struct
    /// can carry these values out without crossing the MLXLLM module's `internal`
    /// access barrier on `LlamaConfiguration`.
    private static func readMetadata(modelDirectory: URL) throws -> ConfigMetadata {
        let configURL = modelDirectory.appendingPathComponent("config.json")
        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch {
            throw ClusterModelLoaderError.configDecodeFailed("Cannot read config.json: \(error)")
        }
        do {
            return try JSONDecoder().decode(ConfigMetadata.self, from: data)
        } catch {
            throw ClusterModelLoaderError.configDecodeFailed(
                "Failed to read hidden_size/num_hidden_layers/vocab_size from config.json: \(error)")
        }
    }

    // MARK: - PP entry point

    /// Bundle of a loaded model and the metadata callers need to build engine configs.
    /// Returning this together avoids a second `config.json` parse in every caller and
    /// makes the actual hidden dimension available without going through model internals.
    /// `@unchecked Sendable` because LlamaModel is a reference type without Sendable
    /// conformance; we ensure exclusive ownership at the call site.
    public struct PPLoadResult: @unchecked Sendable {
        public let model: LlamaModel
        public let hiddenSize: Int
        public let numLayers: Int
        public let vocabSize: Int
    }

    /// Same shape as `PPLoadResult` but for the TP path. The `worldSize` is the
    /// observed size of the `MLX.DistributedGroup` used to build the sharded model;
    /// the caller already holds the `ProviderCore.DistributedGroup` reference.
    public struct TPLoadResult: @unchecked Sendable {
        public let model: LlamaModelTP
        public let worldSize: Int
        public let hiddenSize: Int
        public let numLayers: Int
        public let vocabSize: Int
    }

    /// Load a single-rank `LlamaModel` from `modelDirectory` for pipeline-parallel inference.
    ///
    /// PP does not require a jaccl `DistributedGroup` — each rank runs its own contiguous
    /// layer slice on an independent `LlamaModel` instance. This loader reads `config.json`
    /// and the weight safetensors, constructs a `LlamaModel` (not `LlamaModelTP`), and
    /// applies all weights. The caller is responsible for only running its own layer range
    /// via `callPartial`.
    ///
    /// Returns a `PPLoadResult` carrying the model plus the hidden / layer / vocab dims so
    /// the caller can build an `EncryptedPipelineConfig` with the actual hidden dimension
    /// (not the layer count — a previous version of this loader returned only the model
    /// and the caller had no way to recover the real hidden dim, which broke PP's
    /// activation reshape via `TensorCrypto.openActivation(..., hiddenDim:)`).
    ///
    /// - Parameters:
    ///   - modelDirectory: Directory containing `config.json` and `*.safetensors` weight files.
    /// - Returns: `PPLoadResult` with the loaded model and config metadata.
    /// - Throws: `ClusterModelLoaderError` on any failure.
    public static func loadLlamaModel(modelDirectory: URL) throws -> PPLoadResult {
        // Step 1: Verify config.json exists, then read it twice — once to decode
        // the MLXLLM LlamaConfiguration, once to recover the dimensions we need
        // exposed (LlamaConfiguration's fields are module-internal).
        let configURL = modelDirectory.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw ClusterModelLoaderError.configNotFound(configURL)
        }
        let configData: Data
        do {
            configData = try Data(contentsOf: configURL)
        } catch {
            throw ClusterModelLoaderError.configDecodeFailed("Cannot read config.json: \(error)")
        }
        let config: LlamaConfiguration
        do {
            config = try JSONDecoder().decode(LlamaConfiguration.self, from: configData)
        } catch {
            throw ClusterModelLoaderError.configDecodeFailed("JSON decode failed: \(error)")
        }
        let meta = try readMetadata(modelDirectory: modelDirectory)
        logger.info("ClusterModelLoader.loadLlamaModel: loading from \(modelDirectory.lastPathComponent) hidden=\(meta.hidden_size) layers=\(meta.num_hidden_layers) vocab=\(meta.vocab_size)")

        // Step 2: Construct LlamaModel (single-rank, no DistributedGroup needed).
        let model = LlamaModel(config)

        // Step 3: Load weights using the shared MLXLMCommon helper.
        do {
            try loadWeights(modelDirectory: modelDirectory, model: model)
        } catch {
            throw ClusterModelLoaderError.weightLoadFailed("\(error)")
        }

        logger.info("ClusterModelLoader.loadLlamaModel: LlamaModel loaded successfully")
        return PPLoadResult(
            model: model,
            hiddenSize: meta.hidden_size,
            numLayers: meta.num_hidden_layers,
            vocabSize: meta.vocab_size)
    }

    // MARK: - TP entry point

    /// Load `LlamaModelTP` from `modelDirectory`, using a `DistributedGroup`
    /// that was already initialized by `DistributedGroupBootstrap.bootstrap()`.
    ///
    /// Takes the group as an explicit parameter rather than re-deriving it from
    /// the process environment via `MLX.DistributedGroup()` no-arg init. The
    /// no-arg init falls back to a singleton group (size=1) when the backend
    /// can't form a real distributed group, which would silently produce a
    /// non-functional TP setup. The bootstrap is the single source of truth
    /// for the group; pass it through.
    ///
    /// The function is synchronous for weight loading (MLX arrays are CPU-backed
    /// until eval) but the call itself may block for several seconds on large
    /// checkpoints. Call from a `Task` or background thread as appropriate.
    ///
    /// - Parameters:
    ///   - modelDirectory: Directory containing `config.json` and `*.safetensors` weight files.
    ///   - bootstrapGroup: The `ProviderCore.DistributedGroup` returned by
    ///     `DistributedGroupBootstrap.bootstrap()`. Used here only to verify
    ///     `size > 1` (the bootstrap is the source of truth; this is belt-and-
    ///     braces in case a caller bypasses bootstrap).
    /// - Returns: `TPLoadResult` with the loaded sharded model and config metadata.
    /// - Throws: `ClusterModelLoaderError` on any failure.
    public static func load(
        modelDirectory: URL,
        bootstrapGroup: DistributedGroup
    ) throws -> TPLoadResult {
        // Step 1: Belt-and-braces size check against the bootstrap's group.
        // The bootstrap should have already rejected singleton groups, but
        // reject here too in case some caller path bypasses bootstrap.
        guard bootstrapGroup.size > 1 else {
            throw ClusterModelLoaderError.modelConstructionFailed(
                "TP load requires a multi-rank DistributedGroup; bootstrap returned size=\(bootstrapGroup.size)")
        }

        // Step 2: Verify config.json exists, parse both views.
        let configURL = modelDirectory.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw ClusterModelLoaderError.configNotFound(configURL)
        }

        let configData: Data
        do {
            configData = try Data(contentsOf: configURL)
        } catch {
            throw ClusterModelLoaderError.configDecodeFailed("Cannot read config.json: \(error)")
        }

        let config: LlamaConfiguration
        do {
            config = try JSONDecoder().decode(LlamaConfiguration.self, from: configData)
        } catch {
            throw ClusterModelLoaderError.configDecodeFailed("JSON decode failed: \(error)")
        }
        let meta = try readMetadata(modelDirectory: modelDirectory)

        // Step 3: Get the MLX.DistributedGroup the LlamaModelTP constructor expects.
        // jaccl has been initialized by bootstrap; this returns the global group.
        let mlxGroup = MLX.DistributedGroup()
        guard mlxGroup.size > 1 else {
            throw ClusterModelLoaderError.modelConstructionFailed(
                "MLX.DistributedGroup() returned size=\(mlxGroup.size) after bootstrap (size=\(bootstrapGroup.size)) — group state corrupted between init and use")
        }
        logger.info("ClusterModelLoader: loading from \(modelDirectory.lastPathComponent) rank=\(mlxGroup.rank) size=\(mlxGroup.size) hidden=\(meta.hidden_size)")

        // Step 4: Construct LlamaModelTP.
        let model: LlamaModelTP
        do {
            model = try LlamaModelTP(config, group: mlxGroup)
        } catch {
            throw ClusterModelLoaderError.modelConstructionFailed("\(error)")
        }

        // Step 5: Load and shard weights.
        // `loadWeights` calls `model.sanitize(weights:)` which slices per-rank
        // shards for group.size > 1, then `model.update(parameters:verify:.all)`.
        do {
            try loadWeights(modelDirectory: modelDirectory, model: model)
        } catch {
            throw ClusterModelLoaderError.weightLoadFailed("\(error)")
        }

        logger.info("ClusterModelLoader: LlamaModelTP loaded successfully")
        return TPLoadResult(
            model: model,
            worldSize: mlxGroup.size,
            hiddenSize: meta.hidden_size,
            numLayers: meta.num_hidden_layers,
            vocabSize: meta.vocab_size)
    }
}
