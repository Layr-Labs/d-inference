import Foundation
import ProviderCore

/// The note `models catalog` prints under its table: catalog models this Mac
/// has not downloaded and that the `start`/`switch` picker would let it
/// select. It only prints: nothing is downloaded, selected or saved.
enum ModelsCatalogHint {
    /// Rows printed before the rest are counted.
    static let maximumRows = 3

    static func candidates(
        entries: [CatalogModel], aliases: [CatalogAlias], downloadedIDs: Set<String>, memoryGb: Double,
        runtimeCapabilities: Set<ProviderRuntimeCapability>
    ) -> [CatalogModel] {
        []
    }

    static func lines(candidates: [CatalogModel], cliName: String) -> [String] {
        []
    }
}
