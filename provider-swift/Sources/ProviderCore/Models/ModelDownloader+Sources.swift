import Foundation
import Logging

// Shared by foreground downloads and background prefetch. Every source uses
// the same registry checksums and staged publication gate.
extension ModelDownloader {
    private static let huggingFaceIdleTimeout: TimeInterval = 30
    private static let sourceLogger = Logger(label: "ai.darkbloom.ModelDownloader")

    /// Download a single manifest file into its staging destination, resuming
    /// from a `.part` file when present, verifying size + SHA-256 before
    /// promoting to the final staged path. Each source goes through
    /// `fetchManifestFile`: byte ranges for a large file, else the
    /// resume-capable `downloadFile` (Range requests, Content-Range validation, retries).
    ///
    /// `onChunk(bytesOnDisk)` reports cumulative bytes-on-disk for this file as
    /// it streams, so the foreground path can show live progress; the
    /// background prefetch passes nil and accounts progress per whole file.
    internal func downloadManifestFileWithResume(
        _ job: (file: ManifestFile, destination: URL, url: String),
        huggingFaceArtifact: HuggingFaceArtifact? = nil,
        onChunk: (@Sendable (Int64) -> Void)? = nil
    ) async throws {
        if let artifact = huggingFaceArtifact {
            let hfURL = try artifact.downloadURL(for: job.file.path)
            do {
                let ok = try await fetchManifestFile(
                    job, from: hfURL.absoluteString, attempts: 1,
                    requestTimeout: Self.huggingFaceIdleTimeout, onChunk: onChunk)
                if ok, fileSize(job.destination) == job.file.sizeBytes { return }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                if (error as? URLError)?.code == .cancelled { throw error }
                Self.sourceLogger.warning("Hugging Face download failed; falling back to R2",
                    metadata: ["file": "\(job.file.path)", "error": "\(error)"])
            }
            // Never carry potentially corrupt HF bytes (a prefix or ranges) into the R2 fallback.
            try SegmentedPartFile.remove(partial: job.destination.appendingPathExtension("part"))
            onChunk?(0)
        }
        try Task.checkCancellation()
        let ok = try await fetchManifestFile(job, from: job.url, onChunk: onChunk)
        guard ok else {
            throw ModelCatalogError.downloadFailed("\(job.file.path): required file could not be fetched")
        }
        let size = fileSize(job.destination)
        guard size == job.file.sizeBytes else {
            throw ModelCatalogError.downloadFailed("\(job.file.path): size \(size) != manifest size \(job.file.sizeBytes)")
        }
    }
}
