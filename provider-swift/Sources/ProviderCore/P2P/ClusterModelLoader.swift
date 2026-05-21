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

    // MARK: - Public entry point

    /// Load `LlamaModelTP` from `modelDirectory`.
    ///
    /// Reads the jaccl group from the process environment (set by
    /// `DistributedGroupBootstrap.setEnvironmentVariables` during bootstrap).
    /// Must be called AFTER the bootstrap step on both ranks.
    ///
    /// The function is synchronous for weight loading (MLX arrays are CPU-backed
    /// until eval) but the call itself may block for several seconds on large
    /// checkpoints. Call from a `Task` or background thread as appropriate.
    ///
    /// - Parameters:
    ///   - modelDirectory: Directory containing `config.json` and `*.safetensors` weight files.
    /// - Returns: Loaded and evaluated `LlamaModelTP` ready for inference.
    /// - Throws: `ClusterModelLoaderError` on any failure.
    public static func load(modelDirectory: URL) throws -> LlamaModelTP {
        // Step 1: Read config.json.
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
        logger.info("ClusterModelLoader: loading from \(modelDirectory.lastPathComponent)")

        // Step 2: Get the MLX.DistributedGroup from the process environment.
        // `DistributedGroupBootstrap.setEnvironmentVariables` set MLX_RANK,
        // MLX_JACCL_COORDINATOR, MLX_IBV_DEVICES before this is called.
        // Use the fully-qualified name to resolve MLX.DistributedGroup (the mlx-swift
        // class with a no-arg init) rather than ProviderCore.DistributedGroup (the
        // project's custom struct wrapper).
        let group = MLX.DistributedGroup()
        logger.info("ClusterModelLoader: group rank=\(group.rank) size=\(group.size)")

        // Step 3: Construct LlamaModelTP.
        let model: LlamaModelTP
        do {
            model = try LlamaModelTP(config, group: group)
        } catch {
            throw ClusterModelLoaderError.modelConstructionFailed("\(error)")
        }

        // Step 4: Load and shard weights.
        // `loadWeights` calls `model.sanitize(weights:)` which slices per-rank
        // shards for group.size > 1, then `model.update(parameters:verify:.all)`.
        do {
            try loadWeights(modelDirectory: modelDirectory, model: model)
        } catch {
            throw ClusterModelLoaderError.weightLoadFailed("\(error)")
        }

        logger.info("ClusterModelLoader: LlamaModelTP loaded successfully")
        return model
    }
}
