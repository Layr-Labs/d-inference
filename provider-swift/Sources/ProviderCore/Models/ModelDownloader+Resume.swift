import Crypto
import Foundation

extension ModelDownloader {
    /// Reserve missing file bytes plus scratch space for concurrently fetched
    /// chunks. Only complete, hash-verified chunk prefixes earn resume credit.
    func manifestCapacityRequired(
        jobs: [(file: ManifestFile, destination: URL, url: String)],
        alreadyValid: [Bool],
        huggingFaceArtifact: HuggingFaceArtifact?,
        concurrency: Int
    ) throws -> Int64 {
        var retained = jobs.map { fileSize($0.destination.appendingPathExtension("part")) }
        var scratch: [Int64] = []
        for (index, job) in jobs.enumerated() where !alreadyValid[index] {
            guard let chunks = job.file.r2Chunks else { continue }
            let assembled = job.destination.appendingPathExtension("r2-transfer").appendingPathComponent("assembled")
            var prefix: (bytes: Int64, count: Int) = (0, 0)
            if FileManager.default.fileExists(atPath: assembled.path) {
                let handle = try FileHandle(forReadingFrom: assembled)
                defer { try? handle.close() }
                prefix = try Self.verifiedR2Prefix(handle, chunks: chunks)
            }
            // HF remains first when configured, and downloads a separate full
            // file. Its .part cannot substitute for the chunk assembly or vice versa.
            retained[index] = huggingFaceArtifact == nil ? prefix.bytes : min(prefix.bytes, max(0, retained[index]))
            scratch.append(chunks.dropFirst(prefix.count).map(\.sizeBytes).max() ?? 0)
        }
        let remaining = Self.remainingBytesToFetch(
            sizes: jobs.map(\.file.sizeBytes), alreadyValid: alreadyValid, partBytes: retained)
        return remaining + scratch.sorted(by: >).prefix(max(1, concurrency)).reduce(0, +)
    }

    /// Used during failure cleanup, including cancellation. Hash validation is
    /// deferred until retry so a cancelled task cannot discard useful progress.
    func hasResumableContent(file: ManifestFile, destination: URL) -> Bool {
        if fileSize(destination) == file.sizeBytes || fileSize(destination.appendingPathExtension("part")) > 0 {
            return true
        }
        guard file.r2Chunks != nil else { return false }
        let transfer = destination.appendingPathExtension("r2-transfer")
        return ["assembled", "chunk.bin", "chunk.bin.part"].contains {
            fileSize(transfer.appendingPathComponent($0)) > 0
        }
    }

    /// Reads from the beginning and stops at the first incomplete or corrupt
    /// chunk. Callers truncate torn/corrupt tails before appending new chunks.
    static func verifiedR2Prefix(
        _ handle: FileHandle, chunks: [ManifestChunk]
    ) throws -> (bytes: Int64, count: Int) {
        try handle.seek(toOffset: 0)
        var completed: Int64 = 0
        var count = 0
        for chunk in chunks {
            try Task.checkCancellation()
            guard try hashChunkPrefix(handle, size: chunk.sizeBytes) == chunk.sha256 else { break }
            completed += chunk.sizeBytes
            count += 1
        }
        return (completed, count)
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
