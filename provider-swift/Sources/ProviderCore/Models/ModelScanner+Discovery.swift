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

    /// Fallback load-transient padding; runtime KV/activation reserves are separate.
    private static var memoryOverheadFactor: Double { 1.2 }

    /// Scan for locally cached MLX models, filtering to those that fit in available memory.
    public static func scanModels(hardwareInfo: HardwareInfo) -> [ModelInfo] {
        guard let cacheDir = defaultCacheDirectory() else {
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
        guard let cacheDir = defaultCacheDirectory() else {
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
    public static func scanAllModels(
        in cacheDir: URL, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [ModelInfo] {
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
            entries = []
        }

        var models: [ModelInfo] = []

        for entry in entries {
            let dirName = entry.lastPathComponent

            // HuggingFace stores models in directories like "models--org--name"
            guard dirName.hasPrefix("models--") else { continue }

            let modelName = String(dirName.dropFirst("models--".count))
                .replacingOccurrences(of: "--", with: "/")
            if modelName == ModelMediaPolicy.ownedQwen4ModelID,
                Qwen4LocalModelPath.isConfigured(environment: environment) { continue }

            let snapshotsDir = entry.appendingPathComponent("snapshots", isDirectory: true)
            guard fm.fileExists(atPath: snapshotsDir.path) else { continue }

            guard let latestSnapshot = findLatestSnapshot(in: snapshotsDir) else { continue }

            guard isMLXModel(snapshotDir: latestSnapshot, modelName: modelName) else { continue }

            guard let info = parseModelInfo(snapshotDir: latestSnapshot, modelName: modelName) else {
                continue
            }

            models.append(info)
        }

        if Qwen4LocalModelPath.isConfigured(environment: environment),
            let staged = Qwen4LocalModelPath.directory(environment: environment),
            isMLXModel(snapshotDir: staged, modelName: ModelMediaPolicy.ownedQwen4ModelID),
            let info = parseModelInfo(snapshotDir: staged, modelName: ModelMediaPolicy.ownedQwen4ModelID) {
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

        // Only payloads actually filtered from the native load are excluded.
        // Keep load-transient padding on compute weights, and keep runtime
        // process/OS memory and per-request admission independent of this estimate.
        let mmapExcluded = Qwen4ExpMmapFootprint.excludedBytes(snapshotDir: snapshotDir, modelType: modelType)
        let residentBytes = sizeBytes > mmapExcluded ? sizeBytes - mmapExcluded : sizeBytes
        let nativeLoad = Qwen4ExpLoadFootprint.estimate(
            snapshotDir: snapshotDir, modelType: modelType, sizeBytes: sizeBytes,
            offloadedBytes: mmapExcluded)
        let estimatedMemoryGb = nativeLoad.map { Double($0.totalBytes) / 1_073_741_824 }
            ?? (Double(residentBytes) / 1_073_741_824) * memoryOverheadFactor

        // Advertise whether this build can serve image/video input so the
        // coordinator only routes media requests to a vision-capable provider.
        // nil (not false) for text-only builds, so a freshly-scanned text model is
        // wire-identical to one decoded from an older provider's registration.
        let isVision = FileManager.default.fileExists(atPath: configPath.path)
            && configDeclaresVision(at: configPath, modelID: modelName)

        // Template-render self-check (DAR-130 class): render the model's chat
        // template(s) against canonical request fixtures so the coordinator can
        // refuse to route tool-bearing requests to a (provider, model) whose
        // template throws at request time. nil = no template found (key omitted
        // on the wire); false = some fixture threw (the routing signal).
        // `renderOK` never throws — the startup scan must stay crash-free.
        let templateRenderOK = TemplateRenderCheck.renderOK(at: snapshotDir, modelID: modelName)
        let toolConstraintTemplateHash =
            Gemma4ToolConstraintContract.supports(modelType: modelType)
            ? Gemma4ToolConstraintContract.templateSHA256(at: snapshotDir)
            : nil

        var info = ModelInfo(
            id: modelName,
            modelType: modelType,
            parameters: parameters,
            quantization: quantization,
            sizeBytes: sizeBytes,
            estimatedMemoryGb: estimatedMemoryGb,
            isVision: isVision ? true : nil,
            templateRenderOK: templateRenderOK,
            toolConstraintTemplateHash: toolConstraintTemplateHash,
            ssdOffloadedWeightBytes: mmapExcluded > 0 && mmapExcluded < sizeBytes ? mmapExcluded : nil,
            nativeLoadTransientBytes: nativeLoad?.transientBytes
        )
        if ToolChoiceEnforcementPolicy.advertisesNativeMediaTools(for: info) {
            info.nativeMediaTools = true
        }
        return info
    }

    /// Whether config.json and provider identity policy allow serving media.
    /// Native Qwen4 requires its owned qualified VLM declaration; retained
    /// vision_config alone is insufficient. Mirrors ProviderLoop.modelIsVLM but lives
    /// in the dependency-free scanner so the advertised ModelInfo carries the flag.
    static func configDeclaresVision(at path: URL, modelID: String? = nil) -> Bool {
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return ModelMediaPolicy.advertisesMedia(json, modelID: modelID)
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

        if parameters == nil {
            parameters = estimatedParameterCount(json)
        }

        return (modelType, parameters)
    }

    /// Malformed local metadata must not crash discovery. Preserve the existing
    /// estimate and million-parameter rounding for representable dimensions.
    private static func estimatedParameterCount(_ json: [String: Any]) -> UInt64? {
        func dimension(_ key: String) -> UInt64? {
            if let value = json[key] as? UInt64 { return value }
            guard let value = json[key] as? Int, value >= 0 else { return nil }
            return UInt64(value)
        }
        guard let hidden = dimension("hidden_size"),
            let layers = dimension("num_hidden_layers")
        else { return nil }
        let vocab: UInt64
        if json["vocab_size"] is Int || json["vocab_size"] is UInt64 {
            guard let parsed = dimension("vocab_size") else { return nil }
            vocab = parsed
        } else {
            vocab = 32_000
        }
        let (square, squareOverflow) = hidden.multipliedReportingOverflow(by: hidden)
        let (layerWeights, layerOverflow) = square.multipliedReportingOverflow(by: layers)
        let (allWeights, weightOverflow) = layerWeights.multipliedReportingOverflow(by: 12)
        let (embedding, embeddingOverflow) = vocab.multipliedReportingOverflow(by: hidden)
        let (total, totalOverflow) = (allWeights / 1_000_000 * 1_000_000)
            .addingReportingOverflow(embedding)
        guard !squareOverflow, !layerOverflow, !weightOverflow,
            !embeddingOverflow, !totalOverflow else { return nil }
        return total
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
