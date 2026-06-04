import Foundation
import Logging
import ProviderCoreFoundation

// MARK: - Model Scanner — typed discovery surface
//
// These functions were previously inlined in `ModelScanner.swift` but they
// reference `HardwareInfo`/`ModelInfo` (defined in ProviderCore's
// Protocol/Types.swift) and so can't live in the Linux-buildable
// `ProviderCoreFoundation` target. Keeping them as an extension here
// preserves the existing call sites (`ModelScanner.scanModels(hardwareInfo:)`,
// etc.) without an import-update sweep across the rest of ProviderCore.

extension ModelScanner {

    private static let discoveryLogger = Logger(label: "darkbloom.ModelScanner.Discovery")

    /// Memory overhead multiplier for KV cache, activation buffers, etc.
    private static var memoryOverheadFactor: Double { 1.2 }

    /// Scan for locally cached MLX models, filtering to those that fit in available memory.
    public static func scanModels(hardwareInfo: HardwareInfo) -> [ModelInfo] {
        guard let cacheDir = defaultCacheDirectory(),
              FileManager.default.fileExists(atPath: cacheDir.path) else {
            discoveryLogger.debug("HuggingFace cache directory not found")
            return []
        }
        return scanModels(in: cacheDir, availableMemoryGB: hardwareInfo.memoryAvailableGb)
    }

    /// Scan for ALL locally cached MLX models WITHOUT the available-memory
    /// filter. Diagnostics (`darkbloom doctor`) need this: when the configured
    /// model is too large for this box, `scanModels` drops it, which would make
    /// doctor diagnose some other (fitting) model instead of flagging the one
    /// the operator actually configured and that will never load.
    public static func scanAllModels(hardwareInfo: HardwareInfo) -> [ModelInfo] {
        guard let cacheDir = defaultCacheDirectory(),
              FileManager.default.fileExists(atPath: cacheDir.path) else {
            discoveryLogger.debug("HuggingFace cache directory not found")
            return []
        }
        return scanAllModels(in: cacheDir)
    }

    /// Scan for models in a specific cache directory, filtering by available memory.
    public static func scanModels(in cacheDir: URL, availableMemoryGB: UInt64) -> [ModelInfo] {
        scanAllModels(in: cacheDir).filter { info in
            if info.estimatedMemoryGb <= Double(availableMemoryGB) {
                return true
            }
            discoveryLogger.debug(
                "Skipping \(info.id) — needs \(String(format: "%.1f", info.estimatedMemoryGb)) GB but only \(availableMemoryGB) GB available"
            )
            return false
        }
    }

    /// Scan for every MLX model in a cache directory, unfiltered. The shared
    /// discovery core for both the memory-filtered `scanModels(in:availableMemoryGB:)`
    /// and the diagnostics path.
    public static func scanAllModels(in cacheDir: URL) -> [ModelInfo] {
        let fm = FileManager.default
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: cacheDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            discoveryLogger.warning("Failed to read cache directory \(cacheDir.path): \(error.localizedDescription)")
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

            models.append(info)
        }

        // Sort by estimated memory ascending (smallest models first)
        models.sort { $0.estimatedMemoryGb < $1.estimatedMemoryGb }

        return models
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
                // The division then multiplication rounds to nearest million
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
}
