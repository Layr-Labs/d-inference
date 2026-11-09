import Foundation
import MLXLMCommon

extension DistributedCBv2Engine {
    /// A cluster request's timing in the engine contract's terms, so the bridge
    /// measures the cluster's prefill and decode exactly as it measures a single
    /// Mac's (`EngineV2Bridge+Measurements`). Offsets count from the start of
    /// its admission. Its prompt runs from the owner's start (after every rank
    /// reserved) to the first committed token; its decode from the first to the
    /// last committed token, in MTP rounds when the ranks report them. A
    /// request with media is marked so, and its prefill never counts as a text
    /// rate.
    static func timing(_ state: DistributedRequestState, finishedAt: ContinuousClock.Instant) -> CBv2RequestTiming {
        // Observed offsets are at least 1; 0 means not observed.
        func offset(_ instant: ContinuousClock.Instant?) -> UInt64 {
            guard let instant else { return 0 }
            let elapsed = (instant - state.admissionStartedAt).components
            guard elapsed.seconds >= 0 else { return 1 }
            let whole = UInt64(elapsed.seconds).multipliedReportingOverflow(by: 1_000_000_000)
            let total = whole.partialValue.addingReportingOverflow(UInt64(max(0, elapsed.attoseconds) / 1_000_000_000))
            return whole.overflow || total.overflow ? .max : max(1, total.partialValue)
        }
        var timing = CBv2RequestTiming()
        timing.admittedNanos = offset(state.reservedAt)
        timing.prefillFirstLaunchNanos = timing.admittedNanos
        timing.promptComputedNanos = offset(state.firstTokenAt)
        timing.firstTokenNanos = timing.promptComputedNanos
        timing.lastTokenNanos = offset(state.lastTokenAt)
        timing.lastTokenUptimeNanos = state.lastTokenUptimeNanos
        timing.finishedNanos = offset(finishedAt)
        let decoded = max(0, state.completionTokens - 1)
        let telemetry = state.rankTelemetry
        let rounds = telemetry?.mtpRounds.flatMap { $0 > 0 ? min($0, decoded) : nil } ?? decoded
        timing.decodeSteps = UInt32(clamping: rounds)
        timing.mtpRounds = UInt32(clamping: max(0, telemetry?.mtpRounds ?? 0))
        timing.mtpProposed = UInt32(clamping: max(0, telemetry?.mtpDrafted ?? 0))
        timing.mtpAccepted = UInt32(clamping: max(0, telemetry?.mtpAccepted ?? 0))
        let request = state.request
        let media = request.clusterQwenMedia != nil || request.clusterGLMMedia != nil
            || request.clusterStillImages != nil || request.mimoClusterImages != nil
        timing.visionChunks = media ? 1 : 0
        return timing
    }
}
