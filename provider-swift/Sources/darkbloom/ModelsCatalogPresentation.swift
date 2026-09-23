import Foundation
import ProviderCore

/// Renders extra local cache entries without implying that a similarly named
/// canonical catalog model has been retired.
enum ModelsCatalogPresentation {
    static func localOnlyLines(localModels: [ModelInfo], catalogIDs: Set<String>) -> [String] {
        let localOnly = localModels.filter { !catalogIDs.contains($0.id) }
        guard !localOnly.isEmpty else { return [] }

        var lines = ["", "Local only (not in current catalog)", ""]
        lines += localOnly.map {
            "  \($0.id)  \(String(format: "%.1f", $0.estimatedMemoryGb)) GB"
        }
        lines += [
            "",
            "  Only the IDs in this section are outside the network catalog.",
            "  A checkmark under Supported models means that catalog ID is downloaded.",
            "  It does not confirm that this machine is receiving requests.",
            "  To remove an unused local copy: darkbloom models remove <id>",
        ]
        return lines
    }
}
