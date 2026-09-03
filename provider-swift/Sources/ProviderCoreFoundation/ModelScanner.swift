import Foundation
import Logging

// MARK: - Model Scanner

/// Scans the local HuggingFace cache for downloaded MLX models.
///
/// The HuggingFace cache layout is:
///   {cache}/models--{org}--{name}/snapshots/{hash}/
///
/// where `{cache}` is resolved by `ModelScanner+CacheDirectory.swift`:
/// `$HF_HUB_CACHE`, else `$HUGGINGFACE_HUB_CACHE`, else `$HF_HOME/hub`, else
/// `$XDG_CACHE_HOME/huggingface/hub`, else `~/.cache/huggingface/hub`.
///
/// A valid MLX model has config.json and at least one .safetensors weight file.
///
/// This file holds the platform-neutral primitives (cache discovery, snapshot
/// resolution, integrity-file enumeration, role classification). The MLX/
/// `HardwareInfo`-aware bits (`scanModels`, `parseModelInfo`,
/// `detectQuantization`) live in `ProviderCore` as an extension so the
/// Foundation layer stays buildable on Linux for `darkbloom-publish`.
///
/// This performs fast discovery only (no weight hashing). Call
/// `WeightHasher.computeHash(for:)` separately for models that need attestation.
public struct ModelScanner: Sendable {

    private static let logger = Logger(label: "darkbloom.ModelScanner")

    /// Weight file extensions that count toward model size.
    public static let weightExtensions: Set<String> = [".safetensors", ".npz", ".bin"]

    /// Files included in integrity hashing (weights + config/tokenizer/template).
    ///
    /// Kept in sync with the published model-registry manifest spec. Any file
    /// added here is hashed both during local attestation and during
    /// `darkbloom-publish hash` manifest generation.
    public static let integrityFileNames: Set<String> = [
        "config.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "tokenizer.model",
        "generation_config.json",
        "chat_template.jinja",
        "chat_template.json",
        "quantize_config.json",
        // Added in the Phase 1 model-registry rearchitecture so the manifest
        // covers every file a HuggingFace snapshot ships with:
        "special_tokens_map.json",
        "added_tokens.json",
        "model.safetensors.index.json",
        "vocab.json",
        "merges.txt",
        "preprocessor_config.json",
        "processor_config.json",
        "video_preprocessor_config.json",
    ]

    // MARK: - Public API
    //
    // Cache-directory resolution ($HF_HOME / $HF_HUB_CACHE / ~) lives in
    // ModelScanner+CacheDirectory.swift.

    /// Resolve a model ID to its local snapshot path on disk.
    ///
    /// Checks the HuggingFace cache for a directory matching the model ID.
    /// Returns the snapshot path so the backend can load directly from disk.
    public static func resolveLocalPath(modelID: String) -> URL? {
        resolveLocalPath(
            modelID: modelID,
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    /// Environment-injected form of `resolveLocalPath(modelID:)`.
    public static func resolveLocalPath(
        modelID: String,
        environment: [String: String],
        homeDirectory: URL
    ) -> URL? {
        guard let cacheDir = defaultCacheDirectory(
            environment: environment,
            homeDirectory: homeDirectory
        ) else { return nil }
        let fm = FileManager.default

        // Try exact match: models--{id with / replaced by --}
        let modelDir = cacheDir.appendingPathComponent(
            cacheDirectoryName(for: modelID), isDirectory: true)
        if fm.fileExists(atPath: modelDir.path) {
            let snapshotsDir = modelDir.appendingPathComponent("snapshots", isDirectory: true)
            if let snapshot = findLatestSnapshot(in: snapshotsDir) {
                return snapshot
            }
        }

        // Try without org prefix (for models like "qwen3.5-27b-claude-opus-8bit").
        // Routed through `cacheDirectoryName` so an id containing a slash
        // cannot build a NESTED path (`models--org/name`) instead of a cache
        // directory name.
        let modelDirPlain = cacheDir.appendingPathComponent(
            cacheDirectoryName(for: modelID), isDirectory: true)
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
    ///
    /// The returned URL is symlink-resolved. `contentsOfDirectory(at:)`
    /// canonicalises the paths it hands back (on macOS a `/var/...` input
    /// yields `/private/var/...` entries), so without this the snapshot path
    /// could come back in a different textual form than the cache directory it
    /// was found under -- and callers that compare or key on those paths would
    /// treat one directory as two.
    public static func findLatestSnapshot(in snapshotsDir: URL) -> URL? {
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

        guard let latest else { return nil }
        return resolved(latest.url)
    }

    // MARK: - MLX Detection

    /// Check if a snapshot directory contains an MLX model.
    public static func isMLXModel(snapshotDir: URL, modelName: String) -> Bool {
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

    // MARK: - Weight File Collection

    /// Whether a filename is an integrity-relevant file (weight or config/tokenizer/template).
    public static func isIntegrityFile(_ name: String) -> Bool {
        if weightExtensions.contains(where: { name.hasSuffix($0) }) {
            return true
        }
        if name == "weights.npz" {
            return true
        }
        return integrityFileNames.contains(name)
    }

    /// Whether a filename is a weight file (counts toward model size).
    public static func isWeightFile(_ name: String) -> Bool {
        weightExtensions.contains(where: { name.hasSuffix($0) }) || name == "weights.npz"
    }

    /// Classify a filename into a manifest role.
    ///
    /// Roles are stable identifiers used in `ModelManifest.files[].role` so the
    /// coordinator and verifier can reason about file kinds without re-deriving
    /// from extensions. Pass the BASENAME of the path, not the full path.
    ///
    /// Policy: strict case-sensitive matching against the canonical lowercase
    /// names. HF tooling consistently produces lowercase filenames and the
    /// allow-list / `isIntegrityFile` / `isWeightFile` checks are likewise
    /// case-sensitive (`MODEL.SAFETENSORS` is silently dropped before
    /// reaching this function). Matching strict lowercase here ensures the
    /// macOS (HFS+ case-insensitive) and Linux (ext4 case-sensitive) producers
    /// produce byte-identical manifests.
    public static func roleFor(filename: String) -> String {
        if filename.hasSuffix(".safetensors") || filename.hasSuffix(".npz") || filename.hasSuffix(".bin") || filename == "weights.npz" {
            return "weight"
        }
        if filename == "model.safetensors.index.json" {
            return "index"
        }
        if filename == "tokenizer.json" || filename == "tokenizer_config.json" || filename == "tokenizer.model" ||
           filename == "special_tokens_map.json" || filename == "added_tokens.json" ||
           filename == "vocab.json" || filename == "merges.txt" {
            return "tokenizer"
        }
        if filename == "config.json" || filename == "generation_config.json" || filename == "quantize_config.json" {
            return "config"
        }
        if filename == "chat_template.jinja" || filename == "chat_template.json" {
            return "template"
        }
        if filename == "preprocessor_config.json"
            || filename == "processor_config.json"
            || filename == "video_preprocessor_config.json"
        {
            return "preprocessor"
        }
        return "other"
    }

    /// Collect integrity file paths and total weight size from a snapshot directory.
    ///
    /// Returns (totalWeightSizeBytes, sortedIntegrityFilePaths). Recurses into
    /// subdirectories (e.g. `adapters/`) so any integrity-relevant file under
    /// the snapshot root is included in the manifest. Symlinks are resolved
    /// before the regular-file check so HuggingFace's blob-symlink layout is
    /// handled correctly.
    ///
    /// Only weight files (.safetensors, .npz, .bin) count toward
    /// totalWeightSizeBytes. Config, tokenizer, and template files are
    /// included in the path list for integrity hashing but not in the size
    /// calculation.
    public static func collectWeightFiles(in snapshotDir: URL) -> (sizeBytes: UInt64, paths: [URL]) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: snapshotDir,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (0, [])
        }

        var totalSize: UInt64 = 0
        var paths: [URL] = []

        for case let entry as URL in enumerator {
            let name = entry.lastPathComponent
            guard isIntegrityFile(name) else { continue }

            let isWeight = isWeightFile(name)

            // Resolve symlinks to get actual file size.
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
            // Return the standardised absolute URL (existing callers expect
            // absolute paths; the enumerator already yields absolute URLs).
            paths.append(entry.standardizedFileURL)
        }

        return (totalSize, paths)
    }
}
