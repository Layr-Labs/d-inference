import Foundation
import MLXLMCommon

/// Reviewed prediction-error envelopes. The raw receipt contains the separate
/// calibration/validation samples; these release constants never come from
/// an operator override or an untrusted heartbeat.
public struct DeadlineCalibration: Codable, Sendable, Equatable {
    public var version: Int
    public var promptContractId: String
    public var cells: [DeadlineCalibrationCell]

    enum CodingKeys: String, CodingKey {
        case version, cells
        case promptContractId = "prompt_contract_id"
    }

    var isValid: Bool {
        version == 1 && ServingPerformanceProfiles.validDigest(promptContractId) && !cells.isEmpty
            && cells.count <= 128 && cells.allSatisfy(\.isValid)
    }
}

public struct DeadlineCalibrationCell: Codable, Sendable, Equatable {
    public var promptTokensMin: Int
    public var promptTokensMax: Int
    public var contextTokensMin: Int
    public var contextTokensMax: Int
    public var cacheState: String
    public var contention: String
    public var prefillTps: Double
    public var decodeTps: Double
    public var maxPrefillWorkTokens: Int
    public var maxDecodeWorkTokens: Int
    public var maxActiveRequests: Int
    public var competitorProfileIds: [String]
    public var maxOtherModelRequests: Int
    public var maxOtherModelServiceFraction: Double
    public var errorRatio: Double
    public var errorAdditiveMs: Double
    public var calibrationSampleCount: Int
    public var validationSampleCount: Int
    public var validationCoveredCount: Int
    public var tailCoverage: Double
    public var reportSha256: String

    enum CodingKeys: String, CodingKey {
        case promptTokensMin = "prompt_tokens_min"
        case promptTokensMax = "prompt_tokens_max"
        case contextTokensMin = "context_tokens_min"
        case contextTokensMax = "context_tokens_max"
        case cacheState = "cache_state"
        case contention
        case prefillTps = "prefill_tps"
        case decodeTps = "decode_tps"
        case maxPrefillWorkTokens = "max_prefill_work_tokens"
        case maxDecodeWorkTokens = "max_decode_work_tokens"
        case maxActiveRequests = "max_active_requests"
        case competitorProfileIds = "competitor_profile_ids"
        case maxOtherModelRequests = "max_other_model_requests"
        case maxOtherModelServiceFraction = "max_other_model_service_fraction"
        case errorRatio = "error_ratio"
        case errorAdditiveMs = "error_additive_ms"
        case calibrationSampleCount = "calibration_sample_count"
        case validationSampleCount = "validation_sample_count"
        case validationCoveredCount = "validation_covered_count"
        case tailCoverage = "tail_coverage"
        case reportSha256 = "report_sha256"
    }

    var isValid: Bool {
        guard promptTokensMin > 0, promptTokensMax >= promptTokensMin,
            contextTokensMin > 0, contextTokensMax >= contextTokensMin,
            promptTokensMax <= contextTokensMax,
            ["cold", "reused"].contains(cacheState),
            ["isolated", "same_model", "other_model"].contains(contention),
            prefillTps.isFinite, prefillTps > 0, prefillTps <= 20_000,
            decodeTps.isFinite, decodeTps > 0, decodeTps <= 20_000,
            maxPrefillWorkTokens >= 0, maxDecodeWorkTokens >= 1,
            (1...64).contains(maxActiveRequests),
            maxOtherModelRequests >= 0, maxOtherModelRequests < maxActiveRequests,
            maxOtherModelServiceFraction.isFinite,
            (0...1).contains(maxOtherModelServiceFraction),
            competitorProfileIds == Array(Set(competitorProfileIds)).sorted(),
            competitorProfileIds.count <= 16,
            competitorProfileIds.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
            errorRatio.isFinite, errorRatio >= 1,
            errorAdditiveMs.isFinite, errorAdditiveMs >= 0,
            calibrationSampleCount >= 20, validationSampleCount >= 20,
            validationSampleCount <= 10_000, calibrationSampleCount <= 10_000 - validationSampleCount,
            validationCoveredCount >= 0, validationCoveredCount <= validationSampleCount,
            tailCoverage.isFinite, (0.95..<1).contains(tailCoverage),
            Double(validationCoveredCount) / Double(validationSampleCount) >= tailCoverage,
            ServingPerformanceProfiles.validDigest(reportSha256)
        else { return false }
        guard DeadlineCoverageConfidence.supports(total: validationSampleCount,
            covered: validationCoveredCount, target: tailCoverage) else { return false }
        if contention == "other_model" {
            return maxOtherModelRequests > 0 && maxOtherModelServiceFraction > 0
                && !competitorProfileIds.isEmpty
        }
        return maxOtherModelRequests == 0 && maxOtherModelServiceFraction == 0
            && competitorProfileIds.isEmpty
            && (contention != "isolated" || maxActiveRequests == 1)
            && (contention != "same_model" || maxActiveRequests >= 2)
    }

    /// Live measurements can only lower a reviewed cell's phase rates. The
    /// measured residual still applies to this more conservative base estimate.
    func engineCell(prefillCeiling: Double, decodeCeiling: Double) -> CBv2FirstContentCalibrationCell {
        .init(promptTokensMin: promptTokensMin, promptTokensMax: promptTokensMax,
            contextTokensMin: contextTokensMin, contextTokensMax: contextTokensMax,
            reusedPrefix: cacheState == "reused", contention: contention,
            prefillTokensPerSecond: min(prefillTps, prefillCeiling),
            decodeTokensPerSecond: min(decodeTps, decodeCeiling),
            maxPrefillWorkTokens: maxPrefillWorkTokens, maxDecodeWorkTokens: maxDecodeWorkTokens,
            maxActiveRequests: maxActiveRequests, competitorProfileIDs: competitorProfileIds,
            maxOtherModelRequests: maxOtherModelRequests,
            maxOtherModelServiceFraction: maxOtherModelServiceFraction,
            errorRatio: errorRatio, errorAdditiveMilliseconds: errorAdditiveMs)
    }
}
