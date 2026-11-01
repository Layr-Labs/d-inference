import CryptoKit
import Foundation

/// What a rank that receives its stage keeps on disk: the artifact's files
/// other than its weights. Each is held to the pinned manifest's size and
/// SHA-256; the weight files are neither required nor read.
enum QwenResidentMetadataFiles {
    static let maximumBytes = 256 * 1024 * 1024

    /// Admission has already held the manifest bytes to the registered pin.
    static func verify(_ admission: QwenResidentAdmission) throws -> (fileCount: Int, byteCount: Int) {
        try verify(directory: admission.configuration.modelDirectory, manifest: admission.manifestBytes)
    }

    /// The mechanism alone: `manifest` is whatever the caller trusts.
    static func verify(directory: URL, manifest: Data) throws -> (fileCount: Int, byteCount: Int) {
        let entries = try JSONDecoder().decode(CheckpointManifest.self, from: manifest).files
            .filter { !$0.path.hasSuffix(".safetensors") }
        let bytes = try QwenLongPrefillCheckedBytes.sum(entries.map(\.size_bytes))
        guard !entries.isEmpty, bytes <= maximumBytes, entries.allSatisfy({ !$0.path.contains("/") }) else {
            throw ProbeError("Registered manifest has no bounded top-level metadata files")
        }
        for entry in entries {
            // Opens without following a link and requires a regular file of the pinned size.
            let file = try VerifiedCheckpoint.File(url: directory.appendingPathComponent(entry.path),
                                                   path: entry.path, expectedSize: entry.size_bytes)
            guard try file.digest().map({ String(format: "%02x", $0) }).joined() == entry.sha256 else {
                throw ProbeError("Metadata file differs from its manifest SHA-256: \(entry.path)")
            }
        }
        return (entries.count, bytes)
    }
}
