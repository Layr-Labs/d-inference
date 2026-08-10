/// Production controls for the benchmark-selected Gemma optimization stack.
///
/// Both controls default on so provider configs written before these keys were
/// introduced receive the selected stack. Operators can roll either part back
/// in `provider.toml`; the change takes effect after the provider restarts.
public struct GemmaOptimizationSettings: Sendable, Equatable, Codable {
    /// Submit prefill work every 18 Gemma transformer layers.
    public var prefillLayer18: Bool

    /// Enable the coupled weighted-unsort and safe-R1 expert paths.
    ///
    /// These paths intentionally share one production control. Exposing them
    /// independently could select a combination that was not benchmarked.
    public var weightedR1: Bool

    public init(
        prefillLayer18: Bool = true,
        weightedR1: Bool = true
    ) {
        self.prefillLayer18 = prefillLayer18
        self.weightedR1 = weightedR1
    }

    enum CodingKeys: String, CodingKey {
        case prefillLayer18 = "prefill_layer18"
        case weightedR1 = "weighted_r1"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.prefillLayer18 = try container.decodeIfPresent(
            Bool.self, forKey: .prefillLayer18) ?? true
        self.weightedR1 = try container.decodeIfPresent(
            Bool.self, forKey: .weightedR1) ?? true
    }
}
