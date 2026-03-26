/// ModelCatalog — Static model catalog matching the CLI's known models.
///
/// Mirrors the model catalog from provider/src/main.rs (lines 314-323).
/// Used by SetupWizardView and ModelCatalogView for displaying available
/// models with fit indicators.

import Foundation

enum ModelCatalog {

    struct Entry: Identifiable {
        let id: String
        let name: String
        let sizeGB: Double
        let parameters: String

        /// Whether this model fits in the given amount of memory (GB),
        /// leaving 4 GB headroom for macOS and other processes.
        func fitsInMemory(totalGB: Int) -> Bool {
            sizeGB <= Double(max(totalGB - 4, 1))
        }
    }

    /// Known models from the DGInf catalog, ordered smallest to largest.
    static let models: [Entry] = [
        Entry(id: "mlx-community/Qwen2.5-0.5B-Instruct-4bit", name: "Qwen2.5 0.5B", sizeGB: 0.4, parameters: "0.5B"),
        Entry(id: "mlx-community/Qwen2.5-1.5B-Instruct-4bit", name: "Qwen2.5 1.5B", sizeGB: 1.0, parameters: "1.5B"),
        Entry(id: "mlx-community/Qwen2.5-3B-Instruct-4bit", name: "Qwen2.5 3B", sizeGB: 1.8, parameters: "3B"),
        Entry(id: "mlx-community/Qwen3.5-4B-4bit", name: "Qwen3.5 4B", sizeGB: 2.5, parameters: "4B"),
        Entry(id: "mlx-community/Qwen2.5-7B-Instruct-4bit", name: "Qwen2.5 7B", sizeGB: 4.4, parameters: "7B"),
        Entry(id: "mlx-community/Qwen3.5-9B-Instruct-4bit", name: "Qwen3.5 9B", sizeGB: 5.7, parameters: "9B"),
        Entry(id: "mlx-community/Qwen2.5-14B-Instruct-4bit", name: "Qwen2.5 14B", sizeGB: 8.7, parameters: "14B"),
        Entry(id: "mlx-community/Qwen2.5-32B-Instruct-4bit", name: "Qwen2.5 32B", sizeGB: 19.0, parameters: "32B"),
        Entry(id: "mlx-community/Qwen2.5-72B-Instruct-4bit", name: "Qwen2.5 72B", sizeGB: 42.0, parameters: "72B"),
        Entry(id: "mlx-community/Qwen3.5-122B-Instruct-4bit", name: "Qwen3.5 122B", sizeGB: 72.0, parameters: "122B"),
    ]
}
