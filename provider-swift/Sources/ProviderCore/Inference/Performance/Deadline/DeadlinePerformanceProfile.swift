import Foundation

/// Reviewed first-content evidence for bounded workload cells. This has no
/// authority to change concurrency, chunk policy, memory or serving throughput.
public struct DeadlinePerformanceProfile: Codable, Sendable, Equatable {
    public var id: String
    public var modelId: String
    public var artifactSha256: String
    public var providerVersion: String
    public var runtimeRevision: String
    public var kvBackend: String
    public var chipName: String
    public var gpuCores: UInt32
    public var memoryGb: UInt64
    public var configuredContextTokens: Int
    public var effectiveMaxConcurrency: Int
    public var prefillChunkSize: Int
    public var maxConcurrentPartialPrefills: Int
    public var mixedPrefillTokenCap: Int?
    public var soloPrefillStripeTokens: Int?
    public var minimumWholeMacQuiescenceMs: Int
    public var minimumNominalStabilityMs: Int
    public var powerMode: String
    public var qualificationReportSha256: String
    public var deadlineCalibration: DeadlineCalibration
    public var mtp: ServingMTPConfiguration? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case modelId = "model_id"
        case artifactSha256 = "artifact_sha256"
        case providerVersion = "provider_version"
        case runtimeRevision = "runtime_revision"
        case kvBackend = "kv_backend"
        case chipName = "chip_name"
        case gpuCores = "gpu_cores"
        case memoryGb = "memory_gb"
        case configuredContextTokens = "configured_context_tokens"
        case effectiveMaxConcurrency = "effective_max_concurrency"
        case prefillChunkSize = "prefill_chunk_size"
        case maxConcurrentPartialPrefills = "max_concurrent_partial_prefills"
        case mixedPrefillTokenCap = "mixed_prefill_token_cap"
        case soloPrefillStripeTokens = "solo_prefill_stripe_tokens"
        case minimumWholeMacQuiescenceMs = "minimum_whole_mac_quiescence_ms"
        case minimumNominalStabilityMs = "minimum_nominal_stability_ms"
        case powerMode = "power_mode"
        case qualificationReportSha256 = "qualification_report_sha256"
        case deadlineCalibration = "deadline_calibration"
        case mtp
    }

    public var runtimeConfiguration: DeadlineRuntimeConfiguration {
        .init(configuredContextTokens: configuredContextTokens,
            effectiveMaxConcurrency: effectiveMaxConcurrency, prefillChunkSize: prefillChunkSize,
            maxConcurrentPartialPrefills: maxConcurrentPartialPrefills,
            mixedPrefillTokenCap: mixedPrefillTokenCap, soloPrefillStripeTokens: soloPrefillStripeTokens)
    }

    var applicability: DeadlineApplicability {
        .init(minimumWholeMacQuiescenceMs: minimumWholeMacQuiescenceMs,
            minimumNominalStabilityMs: minimumNominalStabilityMs, powerMode: powerMode)
    }

    var calibratedContextTokensMax: Int {
        deadlineCalibration.cells.map(\.contextTokensMax).max() ?? 0
    }

    var isValid: Bool {
        !id.isEmpty && id.utf8.count <= 256 && !modelId.isEmpty && !providerVersion.isEmpty && !chipName.isEmpty
            && ServingPerformanceProfiles.validDigest(artifactSha256)
            && ServingPerformanceProfiles.validDigest(qualificationReportSha256)
            && runtimeRevision == ServingPerformanceProfiles.runtimeRevision
            && ["paged", "contiguous"].contains(kvBackend) && gpuCores > 0 && memoryGb > 0
            && runtimeConfiguration.isValid && applicability.isValid && (mtp?.isValid ?? true)
            && deadlineCalibration.isValid && deadlineCalibration.cells.allSatisfy {
                $0.promptTokensMax <= configuredContextTokens && $0.contextTokensMax <= configuredContextTokens
            }
    }
}

public enum DeadlinePerformanceProfiles {
    static let detectedHardware = try? HardwareDetector.detect()
    /// Populated only by reviewed, independently validated measurement receipts.
    static let reviewed = DeadlineProfileCatalog.decode(ReviewedDeadlineProfilesData.json)

    static func requiresArtifactHash(modelID: String, profiles: [DeadlinePerformanceProfile] = reviewed) -> Bool {
        profiles.contains { $0.isValid && $0.modelId == modelID }
    }

    static func resolve(
        modelID: String, artifactSHA256: String?, kvBackend: String,
        runtime: DeadlineRuntimeConfiguration, hardware: HardwareInfo?,
        environment: [String: String] = [:], mtp: ServingMTPConfiguration? = nil,
        providerVersion: String = ProviderCore.version,
        profiles: [DeadlinePerformanceProfile] = reviewed
    ) -> DeadlinePerformanceProfile? {
        guard ServingPerformanceProfiles.runtimeOverridesAreAbsent(environment),
            let hash = artifactSHA256, let hardware, runtime.isValid else { return nil }
        return profiles.first {
            $0.isValid && $0.modelId == modelID && $0.artifactSha256 == hash
                && $0.providerVersion == providerVersion && $0.kvBackend == kvBackend
                && $0.chipName == hardware.chipName && $0.gpuCores == hardware.gpuCores
                && $0.memoryGb == hardware.memoryGb && $0.mtp == mtp
                && $0.runtimeConfiguration == runtime
        }
    }
}
