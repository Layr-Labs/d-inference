import Foundation
import os

// MARK: - Model Scanner

/// Scans the local HuggingFace cache for downloaded MLX models.
///
/// The HuggingFace cache layout is:
///   ~/.cache/huggingface/hub/models--{org}--{name}/snapshots/{hash}/
///
/// A valid MLX model has config.json and at least one .safetensors weight file.
/// Memory estimation uses a 1.2x overhead factor for KV cache and runtime buffers.
///
/// This performs fast discovery only (no weight hashing). Call
/// `WeightHasher.computeHash(for:)` separately for models that need attestation.
public struct ModelScanner: Sendable {

    private static let logger = Logger(
        subsystem: "dev.darkbloom.provider",
        category: "ModelScanner"
    )

    /// Memory overhead multiplier for KV cache, activation buffers, etc.
    private static let memoryOverheadFactor: Double = 1.2

    /// Weight file extensions that count toward model size.
    static let weightExtensions: Set<String> = [".safetensors", ".npz", ".bin"]

    /// Files included in integrity hashing (weights + config/tokenizer/template).
    static let integrityFileNames: Set<String> = [
        "config.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "tokenizer.model",
        "generation_config.json",
        "chat_template.jinja",
        "quantize_config.json",
    ]

    // MARK: - Public API

    /// Returns the default HuggingFace cache directory.
    public static func defaultCacheDirectory() -> URL? {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    /// Scan for locally cached MLX models, filtering to those that fit in available memory.
    public static func scanModels(hardwareInfo: HardwareInfo) -> [ModelInfo] {
        guard let cacheDir = defaultCacheDirectory(),
              FileManager.default.fileExists(atPath: cacheDir.path) else {
            logger.debug("HuggingFace cache directory not found")
            return []
        }
        return scanModels(in: cacheDir, availableMemoryGB: hardwareInfo.memoryAvailableGb)
    }

    /// Scan for models in a specific cache directory, filtering by available memory.
    public static func scanModels(in cacheDir: URL, availableMemoryGB: UInt64) -> [ModelInfo] {
        let fm = FileManager.default
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: cacheDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            logger.warning("Failed to read cache directory \(cacheDir.path): \(error.localizedDescription)")
            return []
        }

        var models: [ModelInfo] = []

        for entry in entries {
            let dirName = entry.lastPathComponent

            // HuggingFace stores models in directories like "models--org--name"
            guard dirName.hasPrefix("models--") else { continue }

            let modelName = String(dirName.dropFirst("models--".count))
                .replacingOccurrences(of: "--", with: "/")

            let snapshotsDir = entry.appendingPathComponent("snapshots", isDirectory: true)
            guard fm.fileExists(atPath: snapshotsDir.path) else { continue }

            guard let latestSnapshot = findLatestSnapshot(in: snapshotsDir) else { continue }

            guard isMLXModel(snapshotDir: latestSnapshot, modelName: modelName) else { continue }

            guard let info = parseModelInfo(snapshotDir: latestSnapshot, modelName: modelName) else {
                continue
            }

            if info.estimatedMemoryGb <= Double(availableMemoryGB) {
                models.append(info)
            } else {
                logger.debug(
                    "Skipping \(info.id) — needs \(String(format: "%.1f", info.estimatedMemoryGb)) GB but only \(availableMemoryGB) GB available"
                )
            }
        }

        // Sort by estimated memory ascending (smallest models first)
        models.sort { $0.estimatedMemoryGb < $1.estimatedMemoryGb }

        return models
    }

    /// Resolve a model ID to its local snapshot path on disk.
    ///
    /// Checks the HuggingFace cache for a directory matching the model ID.
    /// Returns the snapshot path so the backend can load directly from disk.
    public static func resolveLocalPath(modelID: String) -> URL? {
        guard let cacheDir = defaultCacheDirectory() else { return nil }
        let fm = FileManager.default

        // Try exact match: models--{id with / replaced by --}
        let dirName = "models--\(modelID.replacingOccurrences(of: "/", with: "--"))"
        let modelDir = cacheDir.appendingPathComponent(dirName, isDirectory: true)
        if fm.fileExists(atPath: modelDir.path) {
            let snapshotsDir = modelDir.appendingPathComponent("snapshots", isDirectory: true)
            if let snapshot = findLatestSnapshot(in: snapshotsDir) {
                return snapshot
            }
        }

        // Try without org prefix (for models like "qwen3.5-27b-claude-opus-8bit")
        let dirNamePlain = "models--\(modelID)"
        let modelDirPlain = cacheDir.appendingPathComponent(dirNamePlain, isDirectory: true)
        if fm.fileExists(atPath: modelDirPlain.path) {
            let snapshotsDir = modelDirPlain.appendingPathComponent("snapshots", isDirectory: true)
            if let snapshot = findLatestSnapshot(in: snapshotsDir) {
                return snapshot
            }
        }

        return nil
    }

    // MARK: - Snapshot Discovery

    /// Find the latest snapshot directory by modification time.
    static func findLatestSnapshot(in snapshotsDir: URL) -> URL? {
        let fm = FileManager.default
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: snapshotsDir,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return nil
        }

        var latest: (url: URL, date: Date)?

        for entry in entries {
            guard let resourceValues = try? entry.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                  resourceValues.isDirectory == true else {
                continue
            }

            let modified = resourceValues.contentModificationDate ?? Date.distantPast

            if latest == nil || modified > latest!.date {
                latest = (entry, modified)
            }
        }

        return latest?.url
    }

    // MARK: - MLX Detection

    /// Check if a snapshot directory contains an MLX model.
    static func isMLXModel(snapshotDir: URL, modelName: String) -> Bool {
        let nameLower = modelName.lowercased()
        let fm = FileManager.default

        // Name contains "mlx" -- definitely MLX
        if nameLower.contains("mlx") {
            return true
        }

        // Check for MLX-specific weight files
        let hasMLXWeights =
            fm.fileExists(atPath: snapshotDir.appendingPathComponent("weights.npz").path)
            || fm.fileExists(atPath: snapshotDir.appendingPathComponent("model.safetensors").path)
            || fm.fileExists(atPath: snapshotDir.appendingPathComponent("model.safetensors.index.json").path)

        // Weight files + quantization indicators in name
        if hasMLXWeights
            && (nameLower.contains("4bit")
                || nameLower.contains("8bit")
                || nameLower.contains("quantized"))
        {
            return true
        }

        // Safetensors + config.json as fallback
        if hasMLXWeights {
            return fm.fileExists(atPath: snapshotDir.appendingPathComponent("config.json").path)
        }

        return false
    }

    // MARK: - Model Parsing

    /// Parse model info from a snapshot directory (fast, no weight hashing).
    static func parseModelInfo(snapshotDir: URL, modelName: String) -> ModelInfo? {
        let configPath = snapshotDir.appendingPathComponent("config.json")

        let (modelType, parameters) = FileManager.default.fileExists(atPath: configPath.path)
            ? parseConfigJSON(at: configPath)
            : (nil, nil)

        let quantization = detectQuantization(modelName: modelName, snapshotDir: snapshotDir)
        let (sizeBytes, _) = collectWeightFiles(in: snapshotDir)

        guard sizeBytes > 0 else { return nil }

        let estimatedMemoryGb = (Double(sizeBytes) / (1024.0 * 1024.0 * 1024.0)) * memoryOverheadFactor

        return ModelInfo(
            id: modelName,
            modelType: modelType,
            parameters: parameters,
            quantization: quantization,
            sizeBytes: sizeBytes,
            estimatedMemoryGb: estimatedMemoryGb
        )
    }

    // MARK: - Config Parsing

    /// Parse config.json to extract model_type and parameter count.
    static func parseConfigJSON(at path: URL) -> (modelType: String?, parameters: UInt64?) {
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }

        let modelType = json["model_type"] as? String

        // Try explicit parameter count first
        var parameters: UInt64?
        if let numParams = json["num_parameters"] as? Int64, numParams > 0 {
            parameters = UInt64(numParams)
        } else if let numParams = json["num_parameters"] as? UInt64 {
            parameters = numParams
        }

        // Estimate from architecture if no explicit count
        if parameters == nil {
            if let hidden = (json["hidden_size"] as? UInt64) ?? (json["hidden_size"] as? Int).map({ UInt64($0) }),
               let layers = (json["num_hidden_layers"] as? UInt64) ?? (json["num_hidden_layers"] as? Int).map({ UInt64($0) })
            {
                let vocab = (json["vocab_size"] as? UInt64)
                    ?? (json["vocab_size"] as? Int).map({ UInt64($0) })
                    ?? 32000
                // Rough estimate: 12 * hidden^2 * layers + vocab * hidden
                // The division then multiplication rounds to nearest million (matches Rust)
                parameters = 12 * hidden * hidden * layers / 1_000_000 * 1_000_000 + vocab * hidden
            }
        }

        return (modelType, parameters)
    }

    // MARK: - Quantization Detection

    /// Detect quantization from model name or config files.
    static func detectQuantization(modelName: String, snapshotDir: URL) -> String? {
        let nameLower = modelName.lowercased()

        if nameLower.contains("4bit") || nameLower.contains("q4") || nameLower.contains("int4") {
            return "4bit"
        }
        if nameLower.contains("8bit") || nameLower.contains("q8") || nameLower.contains("int8") {
            return "8bit"
        }
        if nameLower.contains("3bit") || nameLower.contains("q3") {
            return "3bit"
        }
        if nameLower.contains("bf16") {
            return "bf16"
        }
        if nameLower.contains("fp16") || nameLower.contains("f16") {
            return "fp16"
        }

        // Check for quantize_config.json
        let quantConfigPath = snapshotDir.appendingPathComponent("quantize_config.json")
        if let data = try? Data(contentsOf: quantConfigPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let bits = json["bits"] as? Int, bits > 0
        {
            return "\(bits)bit"
        }

        return nil
    }

    // MARK: - Weight File Collection

    /// Whether a filename is an integrity-relevant file (weight or config/tokenizer/template).
    static func isIntegrityFile(_ name: String) -> Bool {
        if weightExtensions.contains(where: { name.hasSuffix($0) }) {
            return true
        }
        if name == "weights.npz" {
            return true
        }
        return integrityFileNames.contains(name)
    }

    /// Whether a filename is a weight file (counts toward model size).
    static func isWeightFile(_ name: String) -> Bool {
        weightExtensions.contains(where: { name.hasSuffix($0) }) || name == "weights.npz"
    }

    /// Collect integrity file paths and total weight size from a snapshot directory.
    ///
    /// Returns (totalWeightSizeBytes, sortedIntegrityFilePaths).
    /// Only weight files (.safetensors, .npz, .bin) count toward totalWeightSizeBytes.
    /// Config, tokenizer, and template files are included in the path list for
    /// integrity hashing but not in the size calculation.
    static func collectWeightFiles(in snapshotDir: URL) -> (sizeBytes: UInt64, paths: [URL]) {
        let fm = FileManager.default
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: snapshotDir,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return (0, [])
        }

        var totalSize: UInt64 = 0
        var paths: [URL] = []

        for entry in entries {
            let name = entry.lastPathComponent
            guard isIntegrityFile(name) else { continue }

            let isWeight = isWeightFile(name)

            // Resolve symlinks to get actual file size
            let resolvedURL: URL
            if let resourceValues = try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]),
               resourceValues.isSymbolicLink == true
            {
                resolvedURL = entry.resolvingSymlinksInPath()
            } else {
                resolvedURL = entry
            }

            guard let attrs = try? fm.attributesOfItem(atPath: resolvedURL.path),
                  let fileType = attrs[.type] as? FileAttributeType,
                  fileType == .typeRegular else {
                continue
            }

            if isWeight, let fileSize = attrs[.size] as? UInt64 {
                totalSize += fileSize
            }
            paths.append(entry)
        }

        return (totalSize, paths)
    }
}
