/// ModelCatalog — Static model catalog matching the coordinator's catalog.
///
/// Mirrors the model catalog from coordinator/cmd/coordinator/main.go (seedModelCatalog).
/// Used by SetupWizardView and ModelCatalogView for displaying available
/// models with fit indicators and tiered defaults.

import Foundation

enum ModelCatalog {

    struct Entry: Identifiable {
        let id: String
        let name: String
        let modelType: String   // "text"
        let sizeGB: Double
        let architecture: String
        let description: String
        let minRAMGB: Int

        /// Whether this model fits on a machine with the given RAM.
        func fitsInMemory(totalGB: Int) -> Bool {
            totalGB >= minRAMGB
        }
    }

    /// Known models from the Darkbloom catalog, ordered by min RAM tier.
    static let models: [Entry] = [
        Entry(id: "qwen3.5-27b-claude-opus-8bit", name: "Qwen3.5 27B Claude Opus", modelType: "text", sizeGB: 27.0, architecture: "27B dense, Claude Opus distilled", description: "Frontier quality reasoning", minRAMGB: 36),
        Entry(id: "mlx-community/Trinity-Mini-8bit", name: "Trinity Mini", modelType: "text", sizeGB: 26.0, architecture: "27B Adaptive MoE", description: "Fast agentic inference", minRAMGB: 48),
        Entry(id: "mlx-community/Qwen3.5-122B-A10B-8bit", name: "Qwen3.5 122B", modelType: "text", sizeGB: 122.0, architecture: "122B MoE, 10B active", description: "Best quality", minRAMGB: 128),
        Entry(id: "mlx-community/MiniMax-M2.5-8bit", name: "MiniMax M2.5", modelType: "text", sizeGB: 243.0, architecture: "239B MoE, 11B active", description: "SOTA coding, 100 tok/s", minRAMGB: 256),
    ]

    /// Returns the default model for a given RAM tier.
    static func defaultModel(ramGB: Int) -> Entry? {
        if ramGB >= 256 { return models.first { $0.id.contains("MiniMax") } }
        if ramGB >= 128 { return models.first { $0.id.contains("Qwen3.5-122B") } }
        if ramGB >= 36  { return models.first { $0.id.contains("qwen3.5-27b-claude-opus") } }
        return nil
    }

    /// Returns all models that fit in the given RAM but aren't the default.
    static func optionalModels(ramGB: Int) -> [Entry] {
        let defaultId = defaultModel(ramGB: ramGB)?.id
        return models.filter { $0.fitsInMemory(totalGB: ramGB) && $0.id != defaultId }
    }
}
