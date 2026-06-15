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
    /// Keep each streaming buffer small even if the constant changes later.
    private static let maxStreamingBufferSize = 1024 * 1024
    /// Last-resort whole-file reads are only acceptable for small metadata files.
    static let maxWholeFileFallbackBytes: UInt64 = 64 * 1024 * 1024

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

    // MARK: - Change Detection

    /// Cheap change-detection fingerprint for a snapshot directory: the sorted
    /// paths + sizes + mtimes of all integrity files. If the fingerprint is
    /// unchanged since the last full hash, the weights cannot have drifted
    /// (threat model: this guards *accidental* drift on honest providers — a
    /// malicious provider can lie about the reported hash regardless), so the
    /// expensive full re-read can be skipped on model reload.
    ///
    /// Returns nil when the directory has no integrity files or a file cannot
    /// be stat'ed — callers must treat nil as "unknown" and re-hash.
    public static func snapshotFingerprint(snapshotDir: URL) -> String? {
        let (_, paths) = ModelScanner.collectWeightFiles(in: snapshotDir)
        guard !paths.isEmpty else { return nil }
        let fm = FileManager.default
        var parts: [String] = []
        parts.reserveCapacity(paths.count)
        for url in paths.sorted(by: { $0.path < $1.path }) {
            // Stat the TARGET of HF blob-style symlinks, not the link itself —
            // an in-place blob rewrite behind an unchanged link must still
            // change the fingerprint. (attributesOfItem does not traverse.)
            let resolved = url.resolvingSymlinksInPath()
            guard let attrs = try? fm.attributesOfItem(atPath: resolved.path),
                let size = attrs[.size] as? UInt64,
                let mtime = attrs[.modificationDate] as? Date
            else {
                return nil
            }
            parts.append("\(url.path)|\(size)|\(mtime.timeIntervalSince1970)")
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Hashing Implementation

    /// Hash files in sorted filename order, combining per-file digests into a final hash.
    ///
    /// Each file is hashed independently in sorted order, then the
    /// per-file SHA-256 digests are combined in sorted filename order into a single
    /// final SHA-256 hash. This produces a consistent result regardless of filesystem
    /// ordering.
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

        // Combine per-file hashes in sorted order.
        var finalHasher = SHA256()
        for entry in sorted {
            guard let fileDigest = hashSingleFile(at: entry.file) else {
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
    /// Falls back through `InputStream` and, as a last resort, `Data(contentsOf:)`
    /// when `FileHandle` fails. This happens for files moved from URLSession
    /// download temp locations — they retain NSFileProtectionComplete extended
    /// attributes that block raw POSIX open() but are handled transparently by
    /// Foundation URL/file coordination.
    public static func hashSingleFile(at url: URL) -> SHA256Digest? {
        if let digest = hashSingleFileViaHandle(at: url) {
            return digest
        }
        if let digest = hashSingleFileViaInputStream(at: url) {
            return digest
        }
        // Last-resort compatibility fallback: NSData can handle file-protection
        // cases that raw POSIX open() rejects. Keep it to small files so a large
        // shard cannot be copied into memory after both streaming paths fail.
        guard let size = fileSizeBytes(at: url), isWholeFileFallbackAllowed(fileSizeBytes: size) else {
            return nil
        }
        guard let data = withAutoreleasePool({ try? Data(contentsOf: url) }) else {
            return nil
        }
        var hasher = SHA256()
        hasher.update(data: data)
        return hasher.finalize()
    }

    static func isWholeFileFallbackAllowed(fileSizeBytes: UInt64) -> Bool {
        fileSizeBytes <= maxWholeFileFallbackBytes
    }

    static func isStreamingBufferSizeAllowed(_ bytes: Int) -> Bool {
        bytes > 0 && bytes <= maxStreamingBufferSize
    }

    private static func fileSizeBytes(at url: URL) -> UInt64? {
        let path = url.resolvingSymlinksInPath().path
        guard let rawSize = try? FileManager.default.attributesOfItem(atPath: path)[.size] else {
            return nil
        }
        guard let size = rawSize as? NSNumber else {
            return nil
        }
        return size.uint64Value
    }

    private static func withAutoreleasePool<T>(_ body: () -> T) -> T {
        #if canImport(ObjectiveC)
        return autoreleasepool(invoking: body)
        #else
        return body()
        #endif
    }

    private static func hashSingleFileViaHandle(at url: URL) -> SHA256Digest? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        var hasher = SHA256()

        while true {
            guard let chunk = withAutoreleasePool({ try? handle.read(upToCount: bufferSize) }) else {
                return nil
            }
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
        }

        return hasher.finalize()
    }

    private static func hashSingleFileViaInputStream(at url: URL) -> SHA256Digest? {
        guard isStreamingBufferSizeAllowed(bufferSize) else {
            return nil
        }
        guard let stream = InputStream(url: url) else {
            return nil
        }
        stream.open()
        defer { stream.close() }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while true {
            let bytesRead = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                guard let baseAddress = ptr.baseAddress else { return -1 }
                return stream.read(baseAddress, maxLength: bufferSize)
            }
            if bytesRead < 0 {
                return nil
            }
            if bytesRead == 0 {
                break
            }
            buffer.withUnsafeBufferPointer { ptr in
                guard let baseAddress = ptr.baseAddress else { return }
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: baseAddress, count: bytesRead))
            }
        }

        return hasher.finalize()
    }
}
