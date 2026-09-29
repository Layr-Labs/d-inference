import Foundation
import Logging
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Model Scanner

/// Scans the local HuggingFace cache for downloaded MLX models.
///
/// The HuggingFace cache layout is:
///   {cache}/models--{org}--{name}/snapshots/{hash}/
///
/// where `{cache}` is the explicitly saved directory, or the unchanged
/// `~/.cache/huggingface/hub` default. Ambient HuggingFace variables never
/// select a serving cache; the location command can import them explicitly.
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
        "hadamard.json",
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
    // Saved-location and legacy-default resolution lives in
    // ModelScanner+CacheDirectory.swift.

    /// Resolve a model ID to its local snapshot path on disk.
    ///
    /// Checks the HuggingFace cache for a directory matching the model ID.
    /// Returns the snapshot path so the backend can load directly from disk.
    public static func resolveLocalPath(modelID: String) -> URL? {
        resolveLocalPath(
            modelID: modelID,
            environment: ProcessInfo.processInfo.environment,
            configuredDirectory: configuredCacheDirectory)
    }

    public static func resolveLocalPath(
        modelID: String,
        environment: [String: String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        configuredDirectory: String? = nil
    ) -> URL? {
        if modelID == ModelMediaPolicy.ownedQwen4ModelID, Qwen4LocalModelPath.isConfigured(environment: environment) {
            // Invalid explicit staging must not silently serve the old cache.
            return Qwen4LocalModelPath.directory(environment: environment)
        }
        let cacheDir = cacheDirectory(
            homeDirectory: homeDirectory,
            configuredDirectory: configuredDirectory)
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

        return nil
    }

    // MARK: - Snapshot Discovery

    /// Resolve an explicit refs/main selection, or the latest legacy snapshot
    /// by modification time only when that selection is genuinely absent.
    ///
    /// The returned URL is symlink-resolved. `contentsOfDirectory(at:)`
    /// canonicalises the paths it hands back (on macOS a `/var/...` input
    /// yields `/private/var/...` entries), so without this the snapshot path
    /// could come back in a different textual form than the cache directory it
    /// was found under -- and callers that compare or key on those paths would
    /// treat one directory as two.
    public static func findLatestSnapshot(in snapshotsDir: URL) -> URL? {
        let fm = FileManager.default
        // A managed revision is selected explicitly. Modification times must
        // never activate a staged download or undo a rollback.
        let mainRef = snapshotsDir.deletingLastPathComponent().appendingPathComponent("refs/main")
        switch readSnapshotReference(at: mainRef) {
        case .invalid:
            return nil
        case .selected(let raw):
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
                  !name.utf8.contains(0) else { return nil }
            let selected = snapshotsDir.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: selected.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            // Use the same POSIX canonicalization as legacy discovery so one
            // selected directory cannot acquire two cache/ownership identities.
            return resolved(selected)
        case .absent:
            break
        }
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
            // Foundation reports the type of a directory symlink itself.
            // Validate its canonical target, but rank by the original entry's
            // modification date so snapshot-selection ordering is unchanged.
            let candidate = resolved(entry)
            guard let resourceValues = try? entry.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                  let candidateValues = try? candidate.resourceValues(forKeys: [.isDirectoryKey]),
                  candidateValues.isDirectory == true else {
                continue
            }

            let modified = resourceValues.contentModificationDate ?? Date.distantPast

            if latest == nil || modified > latest!.date {
                latest = (candidate, modified)
            }
        }

        guard let latest else { return nil }
        return resolved(latest.url)
    }

    private enum SnapshotReference {
        case absent
        case selected(String)
        case invalid
    }

    /// A failed read is not absence. Keep valid reference symlinks, but do not
    /// follow a broken refs directory into the legacy discovery fallback.
    private static func readSnapshotReference(at url: URL) -> SnapshotReference {
        var named = stat()
        if lstat(url.path, &named) != 0 {
            guard errno == ENOENT else { return .invalid }
            let parent = url.deletingLastPathComponent()
            var parentState = stat()
            if lstat(parent.path, &parentState) == 0 {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { return .invalid }
            } else {
                guard errno == ENOENT else { return .invalid }
            }
            return .absent
        }
        // Reuse the bounded, nonblocking metadata reader policy below. Resolve
        // existing HF links, then refuse special objects and a raced leaf link.
        let reference = url.resolvingSymlinksInPath()
        let fd = open(reference.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .invalid }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var state = stat()
        guard fstat(fd, &state) == 0, (state.st_mode & S_IFMT) == S_IFREG,
              state.st_size >= 0, state.st_size <= 1_048_576,
              let data = try? handle.read(upToCount: 1_048_577),
              data.count == Int(state.st_size),
              let text = String(data: data, encoding: .utf8) else { return .invalid }
        return .selected(text)
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

    /// MiMo's strict native loader consumes one of these source-bound receipts.
    /// Include it in both local attestation and the publisher/downloader file
    /// list. Do not expand the global filename policy: unrelated existing model
    /// aggregates must not change merely because they contain a conversion log.
    private static func modelSpecificIntegrityFileNames(in root: URL) -> Set<String> {
        // HF snapshot symlinks are supported, but never block opening a FIFO
        // or read a special/oversized file during ordinary model discovery.
        let url = root.appendingPathComponent("config.json").resolvingSymlinksInPath()
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return [] }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var state = stat()
        guard fstat(fd, &state) == 0, (state.st_mode & S_IFMT) == S_IFREG,
              state.st_size > 0, state.st_size <= 1_048_576,
              let data = try? handle.read(upToCount: 1_048_577), data.count == Int(state.st_size),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["model_type"] as? String == "mimo_v2" else { return [] }
        return ["conversion_manifest.json", "artifact-provenance.json"]
    }

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
        if filename == "config.json" || filename == "hadamard.json" || filename == "generation_config.json" || filename == "quantize_config.json" {
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
        let modelMetadata = modelSpecificIntegrityFileNames(in: snapshotDir)
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
            let isRootModelMetadata = entry.deletingLastPathComponent().standardizedFileURL == snapshotDir.standardizedFileURL
                && modelMetadata.contains(name)
            guard isIntegrityFile(name) || isRootModelMetadata else { continue }

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
