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
        let modelType: String   // "text", "image", "transcription"
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
        // Transcription
        Entry(id: "CohereLabs/cohere-transcribe-03-2026", name: "Cohere Transcribe", modelType: "transcription", sizeGB: 4.2, architecture: "2B conformer", description: "Best-in-class STT", minRAMGB: 8),

        // Image generation
        Entry(id: "flux_2_klein_4b_q8p.ckpt", name: "FLUX.2 Klein 4B", modelType: "image", sizeGB: 8.1, architecture: "4B diffusion", description: "Fast image gen", minRAMGB: 16),
        Entry(id: "flux_2_klein_9b_q8p.ckpt", name: "FLUX.2 Klein 9B", modelType: "image", sizeGB: 13.0, architecture: "9B diffusion", description: "Higher quality image gen", minRAMGB: 24),

        // Text generation
        Entry(id: "mlx-community/Qwen3.5-4B-4bit", name: "Qwen3.5 4B Contributor", modelType: "text", sizeGB: 4.0, architecture: "4B dense, draft contributor", description: "Internal draft model for disaggregated compute", minRAMGB: 16),
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
        if ramGB >= 16  { return models.first { $0.id.contains("Qwen3.5-4B-4bit") } }
        return models.first { $0.id.contains("cohere-transcribe") }
    }

    /// Returns all models that fit in the given RAM but aren't the default.
    static func optionalModels(ramGB: Int) -> [Entry] {
        let defaultId = defaultModel(ramGB: ramGB)?.id
        return models.filter { $0.fitsInMemory(totalGB: ramGB) && $0.id != defaultId }
    }
}
