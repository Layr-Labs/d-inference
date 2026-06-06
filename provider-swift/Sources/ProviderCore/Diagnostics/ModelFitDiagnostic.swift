import Foundation

/// Pure logic for "can this box actually load the model it would be assigned?"
///
/// A box can be ONLINE and hardware-trusted yet fail every request because the
/// assigned model doesn't fit its RAM ("Insufficient memory (X GB free, need Y
/// GB)"). This turns the raw numbers into an operator-facing verdict.
///
/// Delegates to `ModelLoadAdmission` — the SAME arithmetic the running provider
/// uses in `ProviderLoop.availableMemoryGb()` / `ensureModelLoaded` — so the
/// verdict `doctor` prints can never drift from what the daemon enforces at load
/// time. (Before, this modelled an older `weights × 2.0` / `free × 0.7` gate
/// that no longer matches the runtime.)
public enum ModelFitDiagnostic {
    private static let gib = 1024.0 * 1024.0 * 1024.0

    private static func bytes(_ gb: Double) -> UInt64 {
        guard gb > 0 else { return 0 }
        let b = (gb * gib).rounded()
        return b >= Double(UInt64.max) ? UInt64.max : UInt64(b)
    }

    /// Resident memory (GB) a model needs to load: the (overhead-padded) weight
    /// footprint plus one-request headroom — exactly `ensureModelLoaded`'s
    /// requirement. `estimatedMemoryGb` is the scanner's overhead-included size
    /// (the same value the runtime passes), not the raw on-disk bytes.
    public static func requiredGb(estimatedMemoryGb: Double) -> Double {
        ModelLoadAdmission.requiredToLoadGb(weightsGb: estimatedMemoryGb)
    }

    /// The memory (GB) the provider would actually have free to load a model,
    /// via `ModelLoadAdmission.freeForLoadGb`: real free RAM (clamped to what the
    /// OS reports available when known) minus the OS reserve and resident MLX
    /// memory. Shared with `ProviderLoop.availableMemoryGb()` so they agree.
    ///
    /// - Parameters:
    ///   - systemAvailableGb: real OS-reported available memory (doctor reads it
    ///     live on the same machine). Pass nil when unknown to fall back to the
    ///     total-minus-resident view.
    public static func usableInferenceGb(
        totalGb: Double,
        reserveGb: Double,
        systemAvailableGb: Double? = nil,
        gpuActiveGb: Double = 0,
        gpuCacheGb: Double = 0
    ) -> Double {
        ModelLoadAdmission.freeForLoadGb(
            totalBytes: bytes(totalGb),
            systemAvailableBytes: systemAvailableGb.map(bytes) ?? .max,
            gpuActiveBytes: bytes(gpuActiveGb),
            gpuCacheBytes: bytes(gpuCacheGb),
            reserveBytes: bytes(reserveGb),
            outstandingReservationBytes: 0)
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
    /// `weightGb` is the model's overhead-included estimated size; `alternatives`
    /// are locally-available models, used to suggest a fit.
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
        let needed = requiredGb(estimatedMemoryGb: weightGb)
        if needed <= usableGb {
            return Diagnostic(
                section: .traffic, name: "model fits in RAM", level: .pass,
                message: "\(modelID) needs ~\(fmt(needed)) GB; \(fmt(usableGb)) GB usable.",
                fix: nil)
        }
        let fits = alternatives
            .filter { requiredGb(estimatedMemoryGb: $0.weightGb) <= usableGb }
            .sorted { $0.weightGb > $1.weightGb }
        let suggestion: String
        if fits.isEmpty {
            suggestion = "this box's RAM is too small for the models on this network; consider a machine with more unified memory."
        } else {
            let list = fits.prefix(3).map { "\($0.id) (~\(fmt(requiredGb(estimatedMemoryGb: $0.weightGb))) GB)" }.joined(separator: ", ")
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
