import Foundation

/// Reviewed measurements for one exact serving configuration. This is release
/// data, never a provider/operator assertion that can expand its own admission.
public struct ServingPerformanceProfile: Codable, Sendable, Equatable {
    public struct BatchPoint: Codable, Sendable, Equatable {
        public var width: Int
        public var decodeP10Tps: Double
        public var aggregateDecodeTps: Double
        public var prefillTps: Double
        public var firstContentP95Ms: Double

        enum CodingKeys: String, CodingKey {
            case width
            case decodeP10Tps = "decode_p10_tps"
            case aggregateDecodeTps = "aggregate_decode_tps"
            case prefillTps = "prefill_tps"
            case firstContentP95Ms = "first_content_p95_ms"
        }
    }

    public var id: String
    public var modelId: String
    public var artifactSha256: String
    public var providerVersion: String
    public var runtimeRevision: String
    public var kvBackend: String
    public var chipName: String
    public var gpuCores: UInt32
    public var memoryGb: UInt64
    public var contextTokensMax: Int
    public var maxConcurrency: Int
    public var wholeMacConcurrency: Int
    public var mixedPrefillTokenCap: Int?
    public var qualificationReportSha256: String
    public var batchCurve: [BatchPoint]

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
        case contextTokensMax = "context_tokens_max"
        case maxConcurrency = "max_concurrency"
        case wholeMacConcurrency = "whole_mac_concurrency"
        case mixedPrefillTokenCap = "mixed_prefill_token_cap"
        case qualificationReportSha256 = "qualification_report_sha256"
        case batchCurve = "batch_curve"
    }

    /// Qualification cells remain in the content-addressed report, rather than
    /// growing each heartbeat or allocating a benchmark matrix at every load.
    var isValid: Bool {
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        func digest(_ value: String) -> Bool {
            value.count == 64 && value.unicodeScalars.allSatisfy(hex.contains)
        }
        guard !id.isEmpty, !modelId.isEmpty, digest(artifactSha256),
            digest(qualificationReportSha256), !providerVersion.isEmpty,
            runtimeRevision == ServingPerformanceProfiles.runtimeRevision,
            ["paged", "contiguous"].contains(kvBackend), !chipName.isEmpty,
            gpuCores > 0, memoryGb > 0, contextTokensMax > 0,
            (1...16).contains(maxConcurrency), (1...16).contains(wholeMacConcurrency),
            maxConcurrency <= wholeMacConcurrency,
            mixedPrefillTokenCap.map({ $0 >= 128 && $0 <= 512 }) ?? true,
            batchCurve.first?.width == 1,
            batchCurve.last?.width == maxConcurrency
        else { return false }
        var previousWidth = 0
        var previousThroughput = 0.0
        for point in batchCurve {
            guard point.width > previousWidth, point.width <= maxConcurrency,
                point.decodeP10Tps.isFinite, point.decodeP10Tps >= 30,
                point.aggregateDecodeTps.isFinite, point.aggregateDecodeTps > 0,
                point.prefillTps.isFinite, point.prefillTps > 0, point.prefillTps <= 20_000,
                point.firstContentP95Ms.isFinite, point.firstContentP95Ms > 0,
                point.firstContentP95Ms <= max(3_000, 1.5 * batchCurve[0].firstContentP95Ms),
                previousWidth == 0 || point.aggregateDecodeTps >= previousThroughput * 1.1
            else { return false }
            previousWidth = point.width
            previousThroughput = point.aggregateDecodeTps
        }
        return true
    }
}

public enum ServingPerformanceProfiles {
    /// Changes whenever scheduler/backend semantics affecting qualification do.
    public static let runtimeRevision = "cbv2-first-content-v1"
    public static let legacyMaximumConcurrency = 8
    public static let maximumQualifiedConcurrency = 16
    public static let legacyWholeMacConcurrency = 24
    /// No M5 expansion is certified by the historical M4 B8 evidence. Add
    /// reviewed records alongside the coordinator mirror and measured report.
    static let reviewed: [ServingPerformanceProfile] = []

    /// Standalone loads have no coordinator attestation hash. Compute their
    /// artifact identity on demand when a reviewed model could qualify, even
    /// when reusable prefix caching is disabled. Scanning remains hash-free.
    static func requiresArtifactHash(
        modelID: String, profiles: [ServingPerformanceProfile] = reviewed
    ) -> Bool {
        profiles.contains { $0.isValid && $0.modelId == modelID }
    }

    static func resolve(
        modelID: String, artifactSHA256: String?, kvBackend: String,
        contextTokens: Int?, hardware: HardwareInfo?,
        environment: [String: String] = [:],
        providerVersion: String = ProviderCore.version,
        profiles: [ServingPerformanceProfile] = reviewed
    ) -> ServingPerformanceProfile? {
        guard runtimeOverridesAreAbsent(environment),
            let hash = artifactSHA256, let hardware, let contextTokens,
            contextTokens > 0
        else { return nil }
        return profiles.first { profile in
            profile.isValid && profile.modelId == modelID
                && profile.artifactSha256 == hash
                && profile.providerVersion == providerVersion
                && profile.kvBackend == kvBackend
                && profile.chipName == hardware.chipName
                && profile.gpuCores == hardware.gpuCores
                && profile.memoryGb == hardware.memoryGb
                && contextTokens <= profile.contextTokensMax
        }
    }

    /// Carries explicit widths to final backend resolution. No expansion is
    /// admitted here: unknown profiles are clamped again after artifact/backend
    /// identity is available, before constructing the engine or advertising it.
    static func requestedConcurrency(_ configured: UInt64) -> Int {
        Int(min(max(1, configured), UInt64(maximumQualifiedConcurrency)))
    }

    /// This initial revision qualifies the plain target. Tuning an engine knob
    /// or enabling an assistant changes the measured runtime; do not borrow its
    /// default curve. A future revision can name and qualify those variants.
    static func runtimeOverridesAreAbsent(_ environment: [String: String]) -> Bool {
        !environment.keys.contains {
            $0.hasPrefix("DARKBLOOM_CBV2_") || $0.hasPrefix("DARKBLOOM_QWEN4_")
        }
    }

    static var postureAllowsExpansion: Bool {
        !ProcessInfo.processInfo.isLowPowerModeEnabled && ProcessInfo.processInfo.thermalState == .nominal
    }

    public static func concurrency(configured: UInt64, profile: ServingPerformanceProfile? = nil) -> Int {
        let ceiling = profile?.isValid == true ? profile!.maxConcurrency : legacyMaximumConcurrency
        return Int(min(max(1, configured), UInt64(ceiling)))
    }

    public static func summary(configured: UInt64, automatic: Bool = false) -> String {
        let prefix = automatic ? "Automatic profile selection; unknown profiles keep default 4" :
            "Operator cap \(configured); unknown profiles keep cap \(concurrency(configured: configured))"
        return prefix + "; higher widths require an exact reviewed model/runtime/hardware profile"
    }
}
