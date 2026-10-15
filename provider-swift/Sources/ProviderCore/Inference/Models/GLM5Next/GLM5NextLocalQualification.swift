import Darwin
import Foundation
import ProviderCoreFoundation

/// Explicit operator/test trust input for an offline baseline. The expected
/// aggregate and source commit are supplied independently of the local manifest;
/// this is not an assertion that a directory is ready or a catalog registration.
enum GLM5NextLocalQualification {
    static func plan(
        directory: URL, manifestURL: URL, source: HuggingFaceArtifact,
        expectedAggregateSHA256: String
    ) throws -> GLM5NextArtifactPlan {
        guard manifestURL.isFileURL,
            expectedAggregateSHA256.utf8.count == 64,
            expectedAggregateSHA256.utf8.allSatisfy({
                (48 ... 57).contains($0) || (97 ... 102).contains($0)
            })
        else {
            throw GLM5NextManagedLoadError.invalidManifest
        }
        let fd = open(manifestURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw GLM5NextManagedLoadError.invalidManifest }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var state = stat()
        guard fstat(fd, &state) == 0, state.st_mode & S_IFMT == S_IFREG,
            state.st_size > 0, state.st_size <= 1 << 20
        else { throw GLM5NextManagedLoadError.invalidManifest }
        let data = try handle.read(upToCount: (1 << 20) + 1) ?? Data()
        guard data.count == Int(state.st_size) else {
            throw GLM5NextManagedLoadError.invalidManifest
        }
        let manifest = try ModelCatalogClient.manifestDecoder.decode(ModelManifest.self, from: data)
        guard manifest.aggregateSHA256 == expectedAggregateSHA256,
            manifest.modelID == source.repoID
        else { throw GLM5NextManagedLoadError.identityMismatch }
        let catalog = CatalogModel(
            id: manifest.modelID, s3Name: manifest.r2Prefix,
            displayName: manifest.modelID, modelType: "text",
            sizeGb: Double(manifest.totalSizeBytes) / 1e9,
            version: manifest.version, r2Prefix: manifest.r2Prefix, huggingFaceArtifact: source,
            aggregateSHA256: expectedAggregateSHA256, totalSizeBytes: manifest.totalSizeBytes,
            fileCount: manifest.fileCount)
        return try GLM5NextArtifactPlan.inspect(
            directory: directory, catalog: catalog, manifest: manifest)
    }
}
