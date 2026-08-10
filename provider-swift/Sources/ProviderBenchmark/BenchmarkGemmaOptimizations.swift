import ProviderCore

/// Effective config-backed Gemma posture carried by every benchmark payload.
///
/// The low-level environment is process-local, so a parent wrapper cannot infer
/// these values from its own environment. Recording the config projection in
/// each wrapper-phase subprocess JSON makes ON/OFF artifacts attributable and
/// comparable.
public struct BenchmarkGemmaOptimizations: Codable, Sendable, Equatable {
    public let prefillLayer18: Bool
    public let weightedR1: Bool
    public let environment: [String: String]

    public init(settings: GemmaOptimizationSettings) {
        self.prefillLayer18 = settings.prefillLayer18
        self.weightedR1 = settings.weightedR1
        self.environment = GemmaOptimizationEnvironment.projection(for: settings)
    }
}
