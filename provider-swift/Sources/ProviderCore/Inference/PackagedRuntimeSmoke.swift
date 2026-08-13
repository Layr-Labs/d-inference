// Copyright © 2026 Eigen Labs.

import Darwin
import Foundation
import MLX
import MLXLMCommon
import TOMLKit

/// Runtime gate for the installed provider artifact. Release packaging runs
/// this through the staged app executable before publication.
public enum PackagedRuntimeSmoke {
    public static let pagedCapabilityRelativePath =
        "Contents/Resources/darkbloom-runtime-capabilities/paged-kernel-v1"
    public static let mlxLMCommonBundleName =
        "mlx-swift-lm_MLXLMCommon.bundle"
    public static let gemmaOptimizationSuccessMarker =
        "gemma-optimizations-runtime-smoke: ok"

    static let retainedConfigurationTOML = """
        [gemma_optimizations]
        prefill_layer18 = true
        weighted_r1 = true
        """

    enum VerificationError: Error, Equatable, CustomStringConvertible {
        case unexpectedProjection([String: String])
        case rejectedEnvironmentKeys([String])
        case safeR1NotRequested
        case safeR1AOTUnavailable
        case safeR1CountersArmed

        var description: String {
            switch self {
            case .unexpectedProjection(let projection):
                return "unexpected retained Gemma projection: \(projection)"
            case .rejectedEnvironmentKeys(let keys):
                return "Gemma environment projection rejected keys: \(keys.joined(separator: ","))"
            case .safeR1NotRequested:
                return "safe R1 was not latched as requested"
            case .safeR1AOTUnavailable:
                return "packaged safe R1 AOT kernels are unavailable"
            case .safeR1CountersArmed:
                return "production safe R1 route counters are armed"
            }
        }
    }

    /// Decode and install the retained production controls before the first
    /// GPU access. Deliberately poison all three low-level keys first so this
    /// signed-child gate proves config authority and overwrite precedence,
    /// rather than merely observing a cooperative parent environment.
    ///
    /// The retained projection is computed in `.retainedValidation` context:
    /// `BoundedProcess` merges the parent's environment into this child, so a
    /// foreground/local trust-mode provider (or installer shell) exporting
    /// `MLX_GATHER_QMM_EXPERT_SLICES=trust` must not leak into the expected
    /// safe-R1 value and fail the smoke — the gate validates the retained
    /// config, not the launching environment.
    public static func verifyGemmaOptimizations() throws {
        let config = try retainedConfiguration()
        let projection = GemmaOptimizationEnvironment.projection(
            for: config.gemmaOptimizations,
            context: .retainedValidation)
        try validateRetainedProjection(projection)

        for key in projection.keys {
            _ = setenv(key, "poisoned-by-runtime-smoke", 1)
        }
        try GemmaOptimizationEnvironment.apply(config.gemmaOptimizations)

        let appliedEnvironment = Dictionary(
            uniqueKeysWithValues: projection.keys.compactMap { key in
                let value = key.withCString { name in
                    getenv(name).map { String(cString: $0) }
                }
                return value.map { (key, $0) }
            })
        let rejected = rejectedEnvironmentKeys(
            projection: projection, environment: appliedEnvironment)
        guard rejected.isEmpty else {
            throw VerificationError.rejectedEnvironmentKeys(rejected)
        }

        // Snapshot only. Production must never arm the per-route benchmark
        // counters, which keeps the gather-QMM hot path synchronization-free.
        let diagnostics = GPU.gemma4ExpertQMMDiagnostics()
        try validateSafeR1(
            requested: diagnostics.requested,
            aotAvailable: diagnostics.aotAvailable,
            countersArmed: diagnostics.armed)
    }

    static func retainedConfiguration() throws -> ProviderConfig {
        try TOMLDecoder().decode(
            ProviderConfig.self, from: retainedConfigurationTOML)
    }

    static func validateRetainedProjection(
        _ projection: [String: String]
    ) throws {
        let expected = [
            GemmaOptimizationEnvironment.prefillLayer18Key: "18",
            GemmaOptimizationEnvironment.weightedUnsortKey: "1",
            GemmaOptimizationEnvironment.safeR1Key: "1",
        ]
        guard projection == expected else {
            throw VerificationError.unexpectedProjection(projection)
        }
    }

    static func rejectedEnvironmentKeys(
        projection: [String: String],
        environment: [String: String]
    ) -> [String] {
        projection.compactMap { key, value in
            environment[key] == value ? nil : key
        }.sorted()
    }

    static func validateSafeR1(
        requested: Bool,
        aotAvailable: Bool,
        countersArmed: Bool
    ) throws {
        guard requested else { throw VerificationError.safeR1NotRequested }
        guard aotAvailable else { throw VerificationError.safeR1AOTUnavailable }
        guard !countersArmed else { throw VerificationError.safeR1CountersArmed }
    }

    static func containsGemmaOptimizationSuccessMarker(_ output: Data) -> Bool {
        guard let text = String(data: output, encoding: .utf8) else { return false }
        return text.split(whereSeparator: \.isNewline).contains {
            $0 == Substring(gemmaOptimizationSuccessMarker)
        }
    }

    public static func runPagedKernel(
        shapes: [PagedAttentionKernelSmokeShape] =
            PagedAttentionKernel.gptOSSRuntimeSmokeShapes
    ) throws {
        try PagedAttentionKernel.runtimeSmoke(shapes: shapes)
    }

    public static func runPagedKernel(arguments: [String]) throws {
        let shapes = try arguments.isEmpty
            ? PagedAttentionKernel.gptOSSRuntimeSmokeShapes
            : arguments.map(PagedAttentionKernelSmokeShape.init(argumentValue:))
        try runPagedKernel(shapes: shapes)
    }
}
