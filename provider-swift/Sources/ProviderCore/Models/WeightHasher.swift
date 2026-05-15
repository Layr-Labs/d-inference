import CryptoKit
import Foundation
import os

// MARK: - Weight Hasher

/// On-demand SHA-256 weight hashing for model integrity verification.
///
/// Computes a deterministic hash over all integrity-relevant files in a model
/// snapshot directory. Files are sorted by filename, each hashed independently
/// (in parallel), then the per-file digests are combined into a final hash.
///
/// This is intentionally separated from `ModelScanner` because hashing is
/// expensive (reads every byte of every weight file) and should only be
/// performed for the model actually being served, not during discovery.
public struct WeightHasher: Sendable {

    private static let logger = Logger(
        subsystem: "dev.darkbloom.provider",
        category: "WeightHasher"
    )

    /// Buffer size for streaming file reads (64 KB, matches Rust implementation).
    private static let bufferSize = 65536

    // MARK: - Public API

    /// Compute the integrity hash for a model by its ID.
    ///
    /// Resolves the model ID to its local snapshot path, collects all integrity
    /// files (weights, config, tokenizer, templates), and computes a combined
    /// SHA-256 hash. Returns nil if the model is not found locally or has no
    /// weight files.
    public static func computeHash(for modelID: String) -> String? {
        guard let snapshotDir = ModelScanner.resolveLocalPath(modelID: modelID) else {
            return nil
        }
        return computeHash(snapshotDir: snapshotDir, modelID: modelID)
    }

    /// Compute the integrity hash for a model at a specific snapshot path.
    public static func computeHash(snapshotDir: URL, modelID: String? = nil) -> String? {
        let (_, paths) = ModelScanner.collectWeightFiles(in: snapshotDir)
        guard !paths.isEmpty else { return nil }

        let label = modelID ?? snapshotDir.lastPathComponent
        logger.info("Computing weight hash for \(label) (\(paths.count) files)...")

        let hash = hashFilesSorted(paths)

        if let hash {
            let prefix = String(hash.prefix(16))
            logger.info("Weight hash for \(label): \(prefix)")
        }

        return hash
    }

    // MARK: - Hashing Implementation

    /// Hash files in sorted filename order, combining per-file digests into a final hash.
    ///
    /// Each file is hashed independently (in parallel via DispatchQueue), then the
    /// per-file SHA-256 digests are combined in sorted filename order into a single
    /// final SHA-256 hash. This produces a consistent result regardless of filesystem
    /// ordering and scales across CPU cores for sharded model weights.
    static func hashFilesSorted(_ paths: [URL]) -> String? {
        // Sort by full path (matches Rust's PathBuf::sort which sorts lexicographically)
        let sorted = paths.sorted { $0.path < $1.path }

        // Hash each file in parallel
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "dev.darkbloom.provider.weighthash", attributes: .concurrent)

        // Pre-allocate array for per-file hashes, indexed by position.
        // Safety: each index is written by exactly one concurrent block, no two
        // blocks share an index, and group.wait() provides the happens-before
        // barrier before we read. The nonisolated(unsafe) annotation tells the
        // compiler we've manually verified the data-race safety.
        let count = sorted.count
        let rawBuffer = UnsafeMutablePointer<SHA256Digest?>.allocate(capacity: count)
        rawBuffer.initialize(repeating: nil, count: count)
        nonisolated(unsafe) let buffer = rawBuffer
        defer {
            rawBuffer.deinitialize(count: count)
            rawBuffer.deallocate()
        }

        for (index, path) in sorted.enumerated() {
            group.enter()
            queue.async {
                buffer[index] = hashSingleFile(at: path)
                group.leave()
            }
        }

        group.wait()

        // Combine per-file hashes in sorted order
        var finalHasher = SHA256()
        for i in 0..<count {
            guard let fileDigest = buffer[i] else {
                return nil
            }
            // SHA256Digest doesn't conform to DataProtocol; use withUnsafeBytes
            // to feed the raw 32-byte digest into the final hasher.
            fileDigest.withUnsafeBytes { finalHasher.update(bufferPointer: $0) }
        }

        let finalDigest = finalHasher.finalize()
        return finalDigest.map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 hash a single file by streaming in chunks.
    private static func hashSingleFile(at url: URL) -> SHA256Digest? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        var hasher = SHA256()

        while true {
            guard let chunk = try? handle.read(upToCount: bufferSize) else {
                return nil
            }
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
        }

        return hasher.finalize()
    }
}
