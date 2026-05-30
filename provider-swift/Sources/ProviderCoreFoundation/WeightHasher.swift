import Crypto
import Foundation
import Logging

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

    private static let logger = Logger(label: "darkbloom.WeightHasher")

    /// Buffer size for streaming file reads (64 KB).
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
    ///
    /// Sort key is the full absolute path (matches the legacy provider's behaviour
    /// where there is exactly one snapshot directory per call).
    public static func hashFilesSorted(_ paths: [URL]) -> String? {
        let keyed = paths.map { (file: $0, sortKey: $0.path) }
        return hashFilesWithRelativeKey(keyed)
    }

    /// Hash files in sorted order of the caller-supplied sort key, combining per-file
    /// digests into a final hash. Used by both the legacy attestation path (sort key =
    /// absolute path) and the manifest builder (sort key = relative POSIX path).
    public static func hashFilesWithRelativeKey(_ files: [(file: URL, sortKey: String)]) -> String? {
        let sorted = files.sorted { $0.sortKey < $1.sortKey }

        // Hash each file in parallel.
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "darkbloom.WeightHasher", attributes: .concurrent)

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

        for (index, entry) in sorted.enumerated() {
            group.enter()
            queue.async {
                buffer[index] = hashSingleFile(at: entry.file)
                group.leave()
            }
        }

        group.wait()

        // Combine per-file hashes in sorted order.
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

    /// SHA-256 hash a single file by streaming in chunks. Returns the raw digest
    /// so callers can either hex-encode it or feed it into another hasher.
    ///
    /// Falls back to `Data(contentsOf:)` when `FileHandle` fails. This happens
    /// for files moved from URLSession download temp locations — they retain
    /// NSFileProtectionComplete extended attributes that block raw POSIX open()
    /// but are handled transparently by NSData's file coordination.
    public static func hashSingleFile(at url: URL) -> SHA256Digest? {
        if let digest = hashSingleFileViaHandle(at: url) {
            return digest
        }
        // Fallback: read the entire file via NSData (handles file protection).
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        var hasher = SHA256()
        hasher.update(data: data)
        return hasher.finalize()
    }

    private static func hashSingleFileViaHandle(at url: URL) -> SHA256Digest? {
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
