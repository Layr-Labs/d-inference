import Foundation

extension ModelDownloader {
    /// Applies the shared schema-v1 structure contract, then pins the manifest
    /// to the catalog record that selected it.
    static func validateManifestForDownload(
        _ manifest: ModelManifest,
        model: CatalogModel
    ) throws {
        do {
            try ModelManifestContract.validate(manifest)
        } catch {
            throw ModelCatalogError.downloadFailed(
                "invalid model manifest: \(error.localizedDescription)")
        }
        guard manifest.modelID == model.id else {
            throw ModelCatalogError.downloadFailed(
                "manifest model_id \(manifest.modelID) does not match catalog id \(model.id)")
        }
        if let aggregate = model.aggregateSHA256,
           aggregate != manifest.aggregateSHA256 {
            throw ModelCatalogError.downloadFailed(
                "catalog aggregate hash does not match manifest")
        }
        if let prefix = model.r2Prefix, prefix != manifest.r2Prefix {
            throw ModelCatalogError.downloadFailed(
                "catalog r2_prefix does not match manifest")
        }
    }
}
