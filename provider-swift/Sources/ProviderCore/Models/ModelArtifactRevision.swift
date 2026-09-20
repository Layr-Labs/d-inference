import Crypto
import Foundation

/// Downloaded revisions are immutable and hidden from discovery until refs/main
/// selects one. Keeping preparation separate from activation preserves live
/// engines, supports rollback, and makes process death during download harmless.
extension ModelDownloader {
    static func revisionSnapshotDirectory(manifest: ModelManifest) throws -> URL {
        // The wire aggregate hashes file digests, not their paths. Include the
        // immutable revision and sorted file layout so a rename cannot collide
        // with an existing snapshot. Timestamps and download mirrors are not
        // part of artifact identity and must not break idempotent reuse.
        let identity = ModelRevisionIdentity(manifest)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(identity))
            .map { String(format: "%02x", $0) }.joined()
        return cacheModelDirectory(for: manifest.modelID).appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(".revision-" + digest, isDirectory: true)
    }

    /// Read only the small activation receipt; this is not a replacement for
    /// byte verification during download or attestation.
    static func selectedRevisionMatches(modelID: String, version: String, aggregateSHA256: String) -> Bool {
        guard let directory = ModelScanner.resolveLocalPath(modelID: modelID),
            let data = try? Data(contentsOf: directory.appendingPathComponent(".darkbloom-manifest.json"))
        else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(ModelManifest.self, from: data) else { return false }
        return manifest.modelID == modelID && manifest.version == version && manifest.aggregateSHA256 == aggregateSHA256
    }

    static func validateArtifactManifest(_ manifest: ModelManifest, model: CatalogModel) throws {
        func digest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard manifest.schemaVersion == 1, manifest.modelID == model.id,
            model.version == nil || model.version == manifest.version,
            model.aggregateSHA256 == nil || model.aggregateSHA256 == manifest.aggregateSHA256,
            model.r2Prefix == nil || model.r2Prefix == manifest.r2Prefix,
            digest(manifest.aggregateSHA256), !manifest.files.isEmpty,
            manifest.files.count == manifest.fileCount
        else { throw ModelCatalogError.downloadFailed("manifest does not match the selected model revision") }
        var paths = Set<String>()
        var total: Int64 = 0
        for file in manifest.files {
            let path = try validatedManifestRelativePath(file.path)
            let (sum, overflow) = total.addingReportingOverflow(file.sizeBytes)
            guard !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }),
                paths.insert(path.lowercased()).inserted, digest(file.sha256),
                file.sizeBytes >= 0, !overflow
            else { throw ModelCatalogError.downloadFailed("invalid or duplicate manifest file: \(path)") }
            total = sum
        }
        guard total == manifest.totalSizeBytes else {
            throw ModelCatalogError.downloadFailed("manifest total size does not match its files")
        }
    }

    /// Always verify bytes on reuse; a receipt is never an integrity shortcut.
    static func verifiedRevisionExists(at directory: URL, manifest: ModelManifest) -> Bool {
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        return manifest.files.allSatisfy {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent($0.path).path),
                attrs[.type] as? FileAttributeType == .typeRegular else { return false }
            return attrs[.size] as? Int64 == $0.sizeBytes
        } && WeightHasher.hashFilesWithRelativeKey(manifest.files.map {
            (file: directory.appendingPathComponent($0.path), sortKey: $0.path)
        }) == manifest.aggregateSHA256
    }

    /// Reuse unchanged files from the active revision, including legacy caches.
    /// Copies have independent ownership; never hard-link mutable HF snapshots.
    static func reuseVerifiedFiles(modelID: String, manifest: ModelManifest, stagingDir: URL) throws {
        guard let active = ModelScanner.resolveLocalPath(modelID: modelID) else { return }
        let missing = manifest.files.filter {
            !fileMatches(stagingDir.appendingPathComponent($0.path), size: $0.sizeBytes, sha256: $0.sha256)
        }
        for file in missing {
            try Task.checkCancellation()
            let source = active.appendingPathComponent(file.path).resolvingSymlinksInPath()
            let destination = stagingDir.appendingPathComponent(file.path)
            guard fileMatches(source, size: file.sizeBytes, sha256: file.sha256) else { continue }
            try ensureAvailableCapacity(at: stagingDir, requiredBytes: file.sizeBytes)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    static func publishRevision(stagingDir: URL, directory: URL, manifest: ModelManifest) throws {
        try Task.checkCancellation()
        // Refuse to overwrite even a corrupt immutable snapshot. A running
        // process may still own it. Recovery needs a new revision or removal
        // of the corrupt inactive artifact by its owner.
        if FileManager.default.fileExists(atPath: directory.path) {
            guard verifiedRevisionExists(at: directory, manifest: manifest) else {
                throw ModelCatalogError.downloadFailed("immutable revision is corrupt: \(directory.lastPathComponent)")
            }
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: stagingDir.appendingPathComponent(".darkbloom-manifest.json"), options: .atomic)
        try FileManager.default.moveItem(at: stagingDir, to: directory)
    }

    static func activateRevision(modelID: String, directory: URL) throws {
        let modelDir = cacheModelDirectory(for: modelID)
        let snapshots = modelDir.appendingPathComponent("snapshots", isDirectory: true).standardizedFileURL
        guard directory.deletingLastPathComponent().standardizedFileURL == snapshots,
            FileManager.default.fileExists(atPath: directory.path)
        else { throw ModelCatalogError.downloadFailed("revision is outside this model's snapshot store") }
        let refs = modelDir.appendingPathComponent("refs", isDirectory: true)
        try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
        try directory.lastPathComponent.write(to: refs.appendingPathComponent("main"), atomically: true, encoding: .utf8)
    }
}

/// Stable, path-aware snapshot identity. Derived totals and creation time do not
/// distinguish revisions; the complete file entries and registry identity do.
private struct ModelRevisionIdentity: Encodable {
    let schemaVersion: Int
    let modelID: String
    let version: String
    let r2Prefix: String
    let aggregateSHA256: String
    let files: [ManifestFile]

    init(_ manifest: ModelManifest) {
        schemaVersion = manifest.schemaVersion
        modelID = manifest.modelID
        version = manifest.version
        r2Prefix = manifest.r2Prefix
        aggregateSHA256 = manifest.aggregateSHA256
        files = manifest.files.sorted { $0.path < $1.path }
    }
}
