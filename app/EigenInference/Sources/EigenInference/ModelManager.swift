/// ModelManager — Discovers and manages MLX models on disk.
///
/// Scans the HuggingFace cache directory (`~/.cache/huggingface/hub/`) for
/// downloaded MLX models and reports their names and sizes. Can also trigger
/// new model downloads via `huggingface-cli`.
///
/// MLX models in the HuggingFace cache follow this directory structure:
///   ~/.cache/huggingface/hub/models--<org>--<name>/
///     snapshots/<hash>/
///       config.json
///       *.safetensors
///       tokenizer.json
///       ...
///
/// The model identifier is reconstructed from the directory name by replacing
/// `--` with `/` (e.g., `models--mlx-community--Qwen3.5-4B-4bit` becomes
/// `mlx-community/Qwen3.5-4B-4bit`).

import Foundation

/// A discovered model on disk.
struct LocalModel: Identifiable, Hashable {
    /// HuggingFace model identifier (e.g., "mlx-community/Qwen3.5-4B-4bit").
    let id: String

    /// Human-readable model name (e.g., "Qwen3.5-4B-4bit").
    let name: String

    /// Total size of model files on disk, in bytes.
    let sizeBytes: UInt64

    /// Whether this model is an MLX model (contains mlx or MLX in the path).
    let isMLX: Bool

    /// Returns true when this on-disk model matches either the public API ID
    /// or the source repo ID for a catalog entry.
    func matches(_ entry: ModelCatalog.Entry) -> Bool {
        id == entry.id || id == entry.sourceID
    }
}

/// Discovers HuggingFace-cached models and manages downloads.
///
/// Scans `~/.cache/huggingface/hub/` for model directories, parses their
/// identifiers, computes on-disk size, and can invoke `huggingface-cli download`
/// for new models.
@MainActor
final class ModelManager: ObservableObject {

    /// All discovered local models, sorted by name.
    @Published var availableModels: [LocalModel] = []

    /// Whether a model download is currently in progress.
    @Published var isDownloading = false

    /// Progress message for an active download.
    @Published var downloadStatus = ""

    private let fileManager = FileManager.default

    /// The HuggingFace cache directory.
    private var cacheDir: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
    }

    // MARK: - Scanning

    /// Scan the HuggingFace cache for downloaded models.
    ///
    /// Looks for directories matching `models--*` inside the cache dir,
    /// reconstructs the model identifier, and computes on-disk size from
    /// the latest snapshot.
    func scanModels() {
        var models: [LocalModel] = []

        guard fileManager.fileExists(atPath: cacheDir.path) else {
            availableModels = []
            return
        }

        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: cacheDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            availableModels = []
            return
        }

        for dir in contents {
            let dirName = dir.lastPathComponent
            guard dirName.hasPrefix("models--") else { continue }

            // Reconstruct model ID: models--org--name -> org/name
            let stripped = String(dirName.dropFirst("models--".count))
            let modelId = stripped.replacingOccurrences(of: "--", with: "/")
            let modelName = modelId.components(separatedBy: "/").last ?? modelId

            // Check if it's an MLX model
            let isMLX = modelId.lowercased().contains("mlx")

            // Calculate size from the latest snapshot
            let snapshotsDir = dir.appendingPathComponent("snapshots")
            let size = directorySize(snapshotsDir)

            // Only include if there are actual model files
            if size > 0 {
                models.append(LocalModel(
                    id: modelId,
                    name: modelName,
                    sizeBytes: size,
                    isMLX: isMLX
                ))
            }
        }

        availableModels = models.sorted { $0.name < $1.name }
    }

    /// Check if a model will fit in the available unified memory.
    ///
    /// A rough heuristic: the model's on-disk size (safetensors) is
    /// approximately equal to its memory footprint. We leave 4 GB
    /// headroom for the OS and other processes.
    func fitsInMemory(_ model: LocalModel, totalMemoryGB: Int) -> Bool {
        let availableBytes = UInt64(max(totalMemoryGB - 4, 1)) * 1024 * 1024 * 1024
        return model.sizeBytes <= availableBytes
    }

    // MARK: - Download

    /// Download a model from HuggingFace using huggingface-cli.
    ///
    /// Runs `huggingface-cli download <modelId>` as a subprocess.
    /// Updates `isDownloading` and `downloadStatus` for UI feedback.
    ///
    /// - Parameter modelId: Full HuggingFace model identifier
    ///   (e.g., "mlx-community/Qwen3.5-4B-4bit").
    func downloadModel(_ modelId: String) {
        guard !isDownloading else { return }

        isDownloading = true
        downloadStatus = "Starting download of \(modelId)..."

        Task { [weak self] in
            let exitStatus: Int32
            let errorMessage: String?

            do {
                exitStatus = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global().async {
                        let proc = Process()
                        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                        proc.arguments = ["huggingface-cli", "download", modelId]

                        let pipe = Pipe()
                        proc.standardOutput = pipe
                        proc.standardError = pipe

                        do {
                            try proc.run()
                            proc.waitUntilExit()
                            continuation.resume(returning: proc.terminationStatus)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
                errorMessage = nil
            } catch {
                exitStatus = -1
                errorMessage = error.localizedDescription
            }

            if let errorMessage = errorMessage {
                self?.downloadStatus = "Error: \(errorMessage)"
            } else if exitStatus == 0 {
                self?.downloadStatus = "Downloaded \(modelId)"
                self?.scanModels()
            } else {
                self?.downloadStatus = "Failed to download \(modelId)"
            }
            self?.isDownloading = false
        }
    }

    // MARK: - Helpers

    /// Calculate the total size of all files in a directory, recursively.
    private func directorySize(_ url: URL) -> UInt64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: UInt64 = 0
        for case let file as URL in enumerator {
            if let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize {
                total += UInt64(size)
            }
        }
        return total
    }

    /// Format bytes into a human-readable string (e.g., "4.2 GB").
    nonisolated static func formatSize(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / (1024 * 1024)
        return String(format: "%.0f MB", mb)
    }
}
