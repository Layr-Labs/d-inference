import Foundation

/// Human-readable names for provider runtime capabilities. Unknown values
/// (future capabilities this binary predates) render as their raw wire id so
/// an operator still sees exactly what the catalog asked for.
public enum ProviderCapabilityLabels {
    public static func label(for capability: ProviderRuntimeCapability) -> String {
        switch capability {
        case .appleM5: return "Apple M5"
        case .mlxNAX: return "NAX runtime"
        default: return capability.rawValue
        }
    }

    /// Labels in stable wire-id order, so output does not depend on set
    /// iteration order.
    public static func labels(_ capabilities: Set<ProviderRuntimeCapability>) -> [String] {
        capabilities.sorted().map(label(for:))
    }
}

/// Pure, hardware-free formatting for the "requires:" / "not eligible" lines
/// that `darkbloom models catalog` prints under a model. The daemon already
/// enforces these requirements silently (`advertisedModels` drops ineligible
/// models); these lines are the operator-facing explanation.
public enum ModelRequirementLine {
    /// `requires: Apple M5, NAX runtime`, or nil when nothing is required.
    public static func requires(_ required: Set<ProviderRuntimeCapability>) -> String? {
        guard !required.isEmpty else { return nil }
        return "requires: \(ProviderCapabilityLabels.labels(required).joined(separator: ", "))"
    }

    /// `not eligible on this machine (missing: apple_m5, mlx_nax)`, or nil when
    /// nothing is missing. Uses raw ids so the line matches the download error.
    public static func ineligible(missing: Set<ProviderRuntimeCapability>) -> String? {
        guard !missing.isEmpty else { return nil }
        let ids = missing.sorted().map(\.rawValue).joined(separator: ", ")
        return "not eligible on this machine (missing: \(ids))"
    }

    public static let hardwareUnknown = "eligibility unknown (hardware detection unavailable)"

    /// Every line to print under a catalog entry. Empty when the model has no
    /// requirement. `available == nil` means hardware detection failed, which
    /// must not be reported as "not eligible".
    ///
    /// Goes through `ModelRuntimeRequirements.evaluate` so the embedded
    /// exact-id rule is honoured even when the catalog field is absent.
    public static func lines(
        modelID: String,
        catalogRequirements: [ProviderRuntimeCapability]?,
        available: Set<ProviderRuntimeCapability>?
    ) -> [String] {
        let eligibility = ModelRuntimeRequirements.evaluate(
            modelID: modelID,
            catalogRequirements: catalogRequirements,
            available: available ?? [])
        guard let requiresLine = requires(eligibility.required) else { return [] }

        var lines = [requiresLine]
        if available == nil {
            lines.append(hardwareUnknown)
        } else if let verdict = ineligible(missing: eligibility.missing) {
            lines.append(verdict)
        }
        return lines
    }
}
