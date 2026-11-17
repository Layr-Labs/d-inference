import Foundation
import ProviderCore

/// The note `models catalog` prints under its table: catalog models this Mac
/// has not downloaded and that the `start`/`switch` picker would let it
/// select. It only prints: nothing is downloaded, selected or saved.
enum ModelsCatalogHint {
    /// Rows printed before the rest are counted.
    static let maximumRows = 3

    /// The not-downloaded text models the picker would offer this Mac, larger
    /// first as there: its runtime-capability, alias and hidden-build rules run
    /// on the whole catalog. Of those, a model is named when it is active,
    /// lists a `min_ram_gb` this Mac meets (the coordinator's rule for a listed
    /// tier; its size estimate for an unlisted one is not copied, so those are
    /// left out) and fits the provider's load budget alone, which the tier does
    /// not guarantee. Free disk space, the configured memory reserve, memory in
    /// use at load time, the coordinator's version floor and trust status are
    /// not checked.
    static func candidates(
        entries: [CatalogModel], aliases: [CatalogAlias], downloadedIDs: Set<String>, memoryGb: Double,
        runtimeCapabilities: Set<ProviderRuntimeCapability>
    ) -> [CatalogModel] {
        let rows = Start.pickerCatalogRows(
            catalog: Start.evaluateEligiblePickerCatalog(
                models: entries.filter { $0.modelType == "text" }, aliases: aliases,
                runtimeCapabilities: runtimeCapabilities))
        return Start.buildPickerEntries(
            rows: rows, downloadedIDs: downloadedIDs, localMemoryByID: [:], resumableIDs: [],
            memoryGb: memoryGb
        )
        .filter {
            !$0.downloaded && $0.catalogModel.active != false && ($0.catalogModel.minRamGb ?? 0) > 0
                && Start.pickerSelectionFitsBudget([$0], memoryGb: memoryGb)
        }
        .map(\.catalogModel)
    }

    /// The lines to print after the catalog table; none without a candidate.
    /// Sizes are the catalog's decimal `size_gb`, as in the table.
    static func lines(candidates: [CatalogModel], cliName: String) -> [String] {
        guard !candidates.isEmpty else { return [] }
        var lines = ["", "Not downloaded (this Mac meets their listed requirements)", ""]
        lines += candidates.prefix(maximumRows).map {
            "  \($0.displayName)  [\($0.id)]  ~\(String(format: "%.1f", $0.sizeGb)) GB download"
        }
        if candidates.count > maximumRows {
            lines.append(
                "  … and \(candidates.count - maximumRows) more; the \(cliName) switch picker lists them all")
        }
        return lines + [
            "",
            "  Not checked: free disk space, memory reserved or in use when a model loads, provider version and trust status.",
            "  Download one: \(cliName) models download <id>",
            "  Then choose what to serve: \(cliName) switch (\(cliName) start when the provider is stopped)",
        ]
    }
}
