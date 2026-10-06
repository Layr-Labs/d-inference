import Foundation

extension ModelDownloader {
    /// Call only while holding this model's writer lease. Repairing the small
    /// receipt never substitutes for fresh verification of the immutable bytes.
    /// A missing/corrupt receipt must not turn a valid snapshot into an endless
    /// activation loop, and a receipt must never bless changed model files.
    static func verifyRevisionAndRepairReceipt(at directory: URL, manifest: ModelManifest) throws -> Bool {
        guard verifiedRevisionExists(at: directory, manifest: manifest) else { return false }
        try Task.checkCancellation()
        if let receipt = revisionReceipt(at: directory),
            ModelRevisionIdentity(receipt) == ModelRevisionIdentity(manifest),
            receipt.fileCount == manifest.fileCount, receipt.totalSizeBytes == manifest.totalSizeBytes {
            return true
        }
        try writeRevisionReceipt(manifest, at: directory)
        return true
    }

    static func revisionReceipt(at directory: URL) -> ModelManifest? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(".darkbloom-manifest.json")) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ModelManifest.self, from: data)
    }

    static func writeRevisionReceipt(_ manifest: ModelManifest, at directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: directory.appendingPathComponent(".darkbloom-manifest.json"), options: .atomic)
    }
}
