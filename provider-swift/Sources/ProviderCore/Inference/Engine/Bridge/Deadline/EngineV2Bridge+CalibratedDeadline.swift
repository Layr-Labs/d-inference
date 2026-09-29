import Foundation
import MLXLMCommon

extension EngineV2Bridge {
    /// The bridge verifies release identity and freshness. Actual queue/reuse
    /// matching and the unchanged absolute-clock verdict stay on the engine
    /// queue after all provider-side staging and shared-memory suspensions.
    func calibratedDeadlinePolicy(
        requestID: String, promptTokens: Int, promptWork: PromptWork?,
        now: ContinuousClock.Instant = .now, allowQualifiedPosture: Bool? = nil
    ) -> CBv2FirstContentCalibration? {
        guard let profile = currentDeadlineProfile(
                allowQualifiedPosture: allowQualifiedPosture ?? ServingPerformanceProfiles.postureAllowsExpansion), profile.isValid,
            profile.deadlineCalibration.isValid,
            let identity = promptWorkIdentity,
            identity.promptContractID == profile.deadlineCalibration.promptContractId,
            identity.modelArtifactHash == profile.artifactSha256,
            promptWork?.reconciled(actualPromptTokens: promptTokens, identity: identity) != nil,
            let decode = performanceMeasurements.freshRate("decode", now: now),
            let decodeExpiration = performanceMeasurements.rateExpiration("decode"),
            let work = serviceBudget?.calibrationSnapshot(
                ownerID: serviceOwnerPrefix + ":" + requestID,
                modelID: modelId, profileID: profile.id)
        else { return nil }
        var validUntil = decodeExpiration
        let cells = profile.deadlineCalibration.cells.compactMap { cell -> CBv2FirstContentCalibrationCell? in
            let phase = cell.contention == "isolated" ? "isolated_prefill" : "contended_prefill"
            guard let prefill = performanceMeasurements.freshRate(phase, now: now),
                let expiration = performanceMeasurements.rateExpiration(phase) else { return nil }
            validUntil = min(validUntil, expiration)
            return cell.engineCell(prefillCeiling: prefill, decodeCeiling: decode)
        }
        guard !cells.isEmpty else { return nil }
        return .init(cells: cells, evidenceGuard: work.evidenceGuard,
            sameModelRequests: work.sameModelRequests, otherModelRequests: work.otherModelRequests,
            otherModelServiceFraction: work.otherModelServiceFraction,
            competitorProfileIDs: work.competitorProfileIDs,
            existingContextTokensMax: work.existingContextTokensMax,
            otherModelPrefillTokens: work.otherModelPrefillTokens,
            otherModelDecodeTokens: work.otherModelDecodeTokens, validUntil: validUntil,
            sameModelPrefillTokens: work.sameModelPrefillTokens,
            sameModelDecodeTokens: work.sameModelDecodeTokens)
    }
}
