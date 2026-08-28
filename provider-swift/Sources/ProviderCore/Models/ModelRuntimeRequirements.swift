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
/// metallib hasher; tests supply values without touching MLX or the filesystem.
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
        if naxAvailable(), let hash = liveMetallibHash(), !hash.isEmpty {
            capabilities.insert(.mlxNAX)
        }
        return capabilities
    }

    /// Call once at the process/registration boundary and retain the returned
    /// immutable set for every local gate and the registration message.
    public static func detectLive(hardware: HardwareInfo) -> Set<ProviderRuntimeCapability> {
        // Bind the exact approved-by-hash bytes to MLX before the diagnostic
        // initializes its Metal device/library. The retained /dev/fd snapshot
        // makes later public-path replacement irrelevant to executed kernels.
        let loadedMetallibHash = bindRuntimeMetallibForMLX()
        return detect(
            chipFamily: hardware.chipFamily,
            naxAvailable: { GPU.gemma4ExpertQMMDiagnostics().naxAvailable },
            liveMetallibHash: { loadedMetallibHash })
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
    public static let qwen38RequiredCapabilities: Set<ProviderRuntimeCapability> = [
        .appleM5, .mlxNAX,
    ]

    public static func requiredCapabilities(
        for modelID: String,
        catalogRequirements: [ProviderRuntimeCapability]? = nil
    ) -> Set<ProviderRuntimeCapability> {
        var required = Set(catalogRequirements ?? [])
        if modelID == qwen38ConcreteModelID {
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
