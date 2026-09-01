import Foundation
import MLX

/// A provider runtime capability carried on the registration wire and consumed
/// by catalog eligibility checks. The open value type preserves unknown future
/// capabilities so older providers fail closed for models that require them.
public struct ProviderRuntimeCapability: RawRepresentable, Codable, Hashable, Sendable, Comparable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public static let appleM5 = Self(rawValue: "apple_m5")
    public static let mlxNAX = Self(rawValue: "mlx_nax")
}

/// Pure, dependency-injected capability detection. Production supplies the
/// already-structured HardwareDetector result plus the live MLX diagnostic and
/// bound metallib hash; tests supply values without touching MLX or the
/// filesystem.
public enum ProviderRuntimeCapabilityDetector {
    public static func detect(
        chipFamily: ChipFamily,
        naxAvailable: @Sendable () -> Bool,
        liveMetallibHash: @Sendable () -> String?
    ) -> Set<ProviderRuntimeCapability> {
        var capabilities = Set<ProviderRuntimeCapability>()
        if chipFamily == .m5 {
            capabilities.insert(.appleM5)
        }
        // Resolve the bound hash first. A missing/failed binding must not run a
        // diagnostic that may initialize MLX against unapproved bytes.
        if let hash = liveMetallibHash(), !hash.isEmpty, naxAvailable() {
            capabilities.insert(.mlxNAX)
        }
        return capabilities
    }

    /// Bind `metallibURL` before the first live GPU diagnostic. Passing nil
    /// selects the production loader-visible colocated metallib.
    public static func detectLive(
        hardware: HardwareInfo,
        metallibURL: URL? = nil
    ) -> Set<ProviderRuntimeCapability> {
        detectLive(
            hardware: hardware,
            metallibURL: metallibURL,
            bindMetallib: { bindRuntimeMetallibForMLX(from: $0) },
            naxAvailable: { GPU.gemma4ExpertQMMDiagnostics().naxAvailable }
        )
    }

    static func detectLive(
        hardware: HardwareInfo,
        metallibURL: URL?,
        bindMetallib: @Sendable (URL?) -> String?,
        naxAvailable: @Sendable () -> Bool
    ) -> Set<ProviderRuntimeCapability> {
        let loadedMetallibHash = bindMetallib(metallibURL)
        return detectPrepared(
            hardware: hardware,
            boundMetallibHash: loadedMetallibHash,
            naxAvailable: naxAvailable
        )
    }

    /// Diagnose a runtime whose metallib was already bound at an earlier
    /// startup boundary. Call once and retain the immutable returned set for
    /// every local gate and registration message.
    public static func detectPrepared(
        hardware: HardwareInfo,
        boundMetallibHash: String?
    ) -> Set<ProviderRuntimeCapability> {
        detectPrepared(
            hardware: hardware,
            boundMetallibHash: boundMetallibHash,
            naxAvailable: { GPU.gemma4ExpertQMMDiagnostics().naxAvailable }
        )
    }

    static func detectPrepared(
        hardware: HardwareInfo,
        boundMetallibHash: String?,
        naxAvailable: @Sendable () -> Bool
    ) -> Set<ProviderRuntimeCapability> {
        detect(
            chipFamily: hardware.chipFamily,
            naxAvailable: naxAvailable,
            liveMetallibHash: { boundMetallibHash }
        )
    }
}

public struct ModelRuntimeEligibility: Sendable, Equatable {
    public let modelID: String
    public let required: Set<ProviderRuntimeCapability>
    public let available: Set<ProviderRuntimeCapability>

    public var missing: Set<ProviderRuntimeCapability> {
        required.subtracting(available)
    }

    public var isEligible: Bool { missing.isEmpty }
}

public struct ModelRuntimeIneligibleError: Error, LocalizedError, Sendable, Equatable {
    public static let permanentFailureMarker =
        "permanently ineligible on this provider"

    public let eligibility: ModelRuntimeEligibility

    public var errorDescription: String? {
        let missing = eligibility.missing.sorted().map(\.rawValue).joined(separator: ", ")
        return "Model '\(eligibility.modelID)' is \(Self.permanentFailureMarker): missing runtime capabilities [\(missing)]"
    }
}

/// Shared defense-in-depth evaluator. Catalog requirements are unioned with an
/// embedded exact-ID rule so an old/missing catalog or offline path cannot make
/// the concrete Qwen build eligible. Matching is deliberately case-sensitive.
public enum ModelRuntimeRequirements {
    public static let qwen38ConcreteModelID = "EigenLabs/Qwen3.8-27B-4bit"
    /// Every concrete Qwen3.8-27B build carrying the same target bytes. The
    /// embedded-MTP publication is the pinned target plus its inline head, so
    /// it inherits the target's hardware invariant verbatim — a new build id
    /// must never dodge the gate by renaming.
    public static let qwen38ConcreteModelIDs: Set<String> = [
        qwen38ConcreteModelID,
        "EigenLabs/Qwen3.8-27B-4bit-mtp",
    ]
    public static let qwen38RequiredCapabilities: Set<ProviderRuntimeCapability> = [
        .appleM5, .mlxNAX,
    ]

    public static func requiredCapabilities(
        for modelID: String,
        catalogRequirements: [ProviderRuntimeCapability]? = nil
    ) -> Set<ProviderRuntimeCapability> {
        var required = Set(catalogRequirements ?? [])
        if qwen38ConcreteModelIDs.contains(modelID) {
            required.formUnion(qwen38RequiredCapabilities)
        }
        return required
    }

    public static func evaluate(
        modelID: String,
        catalogRequirements: [ProviderRuntimeCapability]? = nil,
        available: Set<ProviderRuntimeCapability>
    ) -> ModelRuntimeEligibility {
        ModelRuntimeEligibility(
            modelID: modelID,
            required: requiredCapabilities(
                for: modelID, catalogRequirements: catalogRequirements),
            available: available)
    }

    public static func isEligible(
        modelID: String,
        catalogRequirements: [ProviderRuntimeCapability]? = nil,
        available: Set<ProviderRuntimeCapability>
    ) -> Bool {
        evaluate(
            modelID: modelID,
            catalogRequirements: catalogRequirements,
            available: available).isEligible
    }

    public static func requireEligible(
        modelID: String,
        catalogRequirements: [ProviderRuntimeCapability]? = nil,
        available: Set<ProviderRuntimeCapability>
    ) throws {
        let eligibility = evaluate(
            modelID: modelID,
            catalogRequirements: catalogRequirements,
            available: available)
        guard eligibility.isEligible else {
            throw ModelRuntimeIneligibleError(eligibility: eligibility)
        }
    }
}
