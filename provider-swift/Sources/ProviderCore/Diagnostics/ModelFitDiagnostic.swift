import Foundation

/// Pure logic for "can this box actually load the model it would be assigned?"
///
/// A box can be ONLINE and hardware-trusted yet fail every request because the
/// assigned model doesn't fit its RAM ("Insufficient memory (X GB free, need Y
/// GB)"). This turns the raw numbers into an operator-facing verdict.
public enum ModelFitDiagnostic {
    /// Matches the provider's own load-time headroom multiplier
    /// (ensureModelLoaded uses ~2.0× the on-disk weight size for weights + KV +
    /// activations). A model "fits" when weightGb * factor <= usable RAM.
    public static let memoryHeadroomFactor = 2.0

    /// Resident memory a model needs to load, from its on-disk weight size.
    public static func requiredGb(weightGb: Double) -> Double {
        weightGb * memoryHeadroomFactor
    }

    /// A candidate model the operator could serve instead, with its size.
    public struct ModelOption: Sendable, Equatable {
        public let id: String
        public let weightGb: Double
        public init(id: String, weightGb: Double) {
            self.id = id
            self.weightGb = weightGb
        }
    }

    /// Builds the traffic-readiness diagnostic for a single target model.
    /// `alternatives` are locally-available models, used to suggest a fit.
    public static func diagnose(
        modelID: String,
        weightGb: Double,
        usableGb: Double,
        alternatives: [ModelOption] = []
    ) -> Diagnostic {
        guard weightGb > 0, usableGb > 0 else {
            return Diagnostic(
                section: .traffic, name: "model fits in RAM", level: .warn,
                message: "couldn't determine the model size or available memory; skipping the fit check.",
                fix: nil)
        }
        let needed = requiredGb(weightGb: weightGb)
        if needed <= usableGb {
            return Diagnostic(
                section: .traffic, name: "model fits in RAM", level: .pass,
                message: "\(modelID) needs ~\(fmt(needed)) GB; \(fmt(usableGb)) GB usable.",
                fix: nil)
        }
        let fits = alternatives
            .filter { requiredGb(weightGb: $0.weightGb) <= usableGb }
            .sorted { $0.weightGb > $1.weightGb }
        let suggestion: String
        if fits.isEmpty {
            suggestion = "this box's RAM is too small for the models on this network; consider a machine with more unified memory."
        } else {
            let list = fits.prefix(3).map { "\($0.id) (~\(fmt(requiredGb(weightGb: $0.weightGb))) GB)" }.joined(separator: ", ")
            suggestion = "set `enabled_models` in provider.toml to a model that fits: \(list)."
        }
        return Diagnostic(
            section: .traffic, name: "model fits in RAM", level: .fail,
            message: "\(modelID) needs ~\(fmt(needed)) GB but only \(fmt(usableGb)) GB is usable — it will show online but every request fails to load.",
            fix: suggestion)
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%.1f", v)
    }
}
