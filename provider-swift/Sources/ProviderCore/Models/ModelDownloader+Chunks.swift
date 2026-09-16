import Crypto
import Foundation

extension ModelDownloader {
    static func validateR2Chunks(_ file: ManifestFile) throws {
        guard let chunks = file.r2Chunks else { return }
        guard !chunks.isEmpty, chunks.count <= 4096, file.sizeBytes > 0 else {
            throw ModelCatalogError.downloadFailed("invalid R2 chunk count for \(file.path)")
        }
        var remaining = file.sizeBytes
        for chunk in chunks {
            guard chunk.sizeBytes > 0, chunk.sizeBytes < 500_000_000,
                  chunk.sizeBytes <= remaining, chunk.sha256.utf8.count == 64,
                  chunk.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw ModelCatalogError.downloadFailed("invalid R2 chunk for \(file.path)")
            }
            remaining -= chunk.sizeBytes
        }
        guard remaining == 0 else {
            throw ModelCatalogError.downloadFailed("R2 chunk sizes do not match \(file.path)")
        }
    }

    static func validateChunkedManifest(_ manifest: ModelManifest) throws {
        var count = 0
        let paths = manifest.files.map { $0.path.lowercased() }
        for file in manifest.files {
            try validateR2Chunks(file)
            guard let chunks = file.r2Chunks else { continue }
            count += chunks.count
            guard count <= 4096 else { throw ModelCatalogError.downloadFailed("too many R2 chunks") }
            for suffix in [".chunks", ".r2-transfer"] {
                let reserved = file.path.lowercased() + suffix
                guard !paths.contains(where: { $0 == reserved || $0.hasPrefix(reserved + "/") }) else {
                    throw ModelCatalogError.downloadFailed("model file overlaps chunk storage")
                }
            }
        }
    }

    /// Keep one transport chunk plus the assembled prefix on disk. On restart,
    /// re-hash complete prefix chunks and truncate any interrupted append.
    /// Never buffer a whole chunk or shard in memory.
    func downloadR2Chunks(
        _ job: (file: ManifestFile, destination: URL, url: String),
        chunks: [ManifestChunk],
        onChunk: (@Sendable (Int64) -> Void)?
    ) async throws {
        let fm = FileManager.default
        let directory = job.destination.appendingPathExtension("r2-transfer")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let assembled = directory.appendingPathComponent("assembled")
        let piece = directory.appendingPathComponent("chunk.bin")
        if !fm.fileExists(atPath: assembled.path) {
            guard fm.createFile(atPath: assembled.path, contents: nil) else {
                throw ModelCatalogError.downloadFailed("cannot create chunk assembly")
            }
        }
        let output = try FileHandle(forUpdating: assembled)
        defer { try? output.close() }
        var completed: Int64 = 0
        var firstMissing = 0
        for chunk in chunks {
            try Task.checkCancellation()
            guard try Self.hashChunkPrefix(output, size: chunk.sizeBytes) == chunk.sha256 else { break }
            completed += chunk.sizeBytes
            firstMissing += 1
        }
        try output.truncate(atOffset: UInt64(completed))
        try output.seek(toOffset: UInt64(completed))
        onChunk?(completed)

        // Account for the temporary chunk as well as the remaining assembly.
        let scratch = chunks.map(\.sizeBytes).max() ?? 0
        try Self.ensureAvailableCapacity(at: directory, requiredBytes: job.file.sizeBytes - completed + scratch)
        for index in firstMissing..<chunks.count {
            try Task.checkCancellation()
            let chunk = chunks[index]
            let base = completed
            if !Self.fileMatches(piece, size: chunk.sizeBytes, sha256: chunk.sha256) {
                let ok = try await downloadFile(
                    from: job.url + String(format: ".chunks/%06d.bin", index),
                    to: piece, label: "\(job.file.path) chunk \(index + 1)/\(chunks.count)",
                    onProgress: nil, required: true, expectedSHA256: chunk.sha256,
                    maximumBytes: chunk.sizeBytes,
                    onChunk: { bytes in onChunk?(base + bytes) })
                guard ok, fileSize(piece) == chunk.sizeBytes else {
                    throw ModelCatalogError.downloadFailed("R2 chunk size mismatch")
                }
            }
            let input = try FileHandle(forReadingFrom: piece)
            do {
                while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
                    try Task.checkCancellation()
                    try output.write(contentsOf: data)
                }
                try input.close()
            } catch {
                try? input.close()
                throw error
            }
            try output.synchronize()
            completed += chunk.sizeBytes
            try fm.removeItem(at: piece)
            onChunk?(completed)
        }
        guard Self.fileMatches(assembled, size: job.file.sizeBytes, sha256: job.file.sha256) else {
            // Incorrect chunk metadata must not poison all subsequent retries.
            try output.truncate(atOffset: 0)
            throw ModelCatalogError.downloadFailed("reconstructed SHA-256 mismatch for \(job.file.path)")
        }
        try output.close()
        if fm.fileExists(atPath: job.destination.path) { try fm.removeItem(at: job.destination) }
        try fm.moveItem(at: assembled, to: job.destination)
        try fm.removeItem(at: directory)
    }

    private static func hashChunkPrefix(_ handle: FileHandle, size: Int64) throws -> String? {
        var remaining = size
        var hash = SHA256()
        while remaining > 0 {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: Int(min(remaining, 1024 * 1024))), !data.isEmpty else { return nil }
            hash.update(data: data)
            remaining -= Int64(data.count)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
