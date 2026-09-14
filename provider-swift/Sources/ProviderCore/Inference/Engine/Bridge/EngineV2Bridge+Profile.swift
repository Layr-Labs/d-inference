import Foundation
import MLXLMCommon

// Engine → wire profile glue (system profiler slice 3). The engine exports
// `CBv2RequestTiming` on the terminal usage (nanosecond offsets from engine
// enqueue in the DispatchTime domain plus step/prefill/MTP counters); this
// maps it onto the closed `EngineProfile` wire object. Numerics only.

extension EngineProfile {
    /// Builds the wire sub-object from the engine's terminal timing. Zero
    /// stamps stay nil (never observed) so the coordinator's order checks skip
    /// them; counters are copied verbatim.
    init(timing t: CBv2RequestTiming, finishReason: CBv2FinishReason?) {
        self.init()
        func ns(_ v: UInt64) -> Int64? { v == 0 ? nil : Int64(clamping: v) }
        func n(_ v: UInt32) -> Int64 { Int64(v) }
        admittedNs = ns(t.admittedNanos)
        kvAllocatedNs = ns(t.kvAllocatedNanos)
        prefillFirstLaunchNs = ns(t.prefillFirstLaunchNanos)
        promptComputedNs = ns(t.promptComputedNanos)
        firstTokenNs = ns(t.firstTokenNanos)
        finishedNs = ns(t.finishedNanos)
        readmissions = n(t.readmissions)
        preemptions = n(t.preemptions)
        capacityRequeues = n(t.capacityRequeues)
        prefillChunks = n(t.prefillChunks)
        packedPrefillChunks = n(t.packedPrefillChunks)
        visionChunks = n(t.visionChunks)
        soloStripeChunks = n(t.soloStripeChunks)
        prefillChunkTokensMax = n(t.prefillChunkTokensMax)
        decodeSteps = n(t.decodeSteps)
        chainedDecodeSteps = n(t.chainedDecodeSteps)
        batchRowsSum = Int64(clamping: t.batchRowsSum)
        batchRowsMin = n(t.batchRowsMin)
        batchRowsMax = n(t.batchRowsMax)
        stepLatencyNsSum = Int64(clamping: t.stepLatencyNanosSum)
        stepLatencyNsMax = Int64(clamping: t.stepLatencyNanosMax)
        mtpRounds = n(t.mtpRounds)
        mtpProposed = n(t.mtpProposed)
        mtpAccepted = n(t.mtpAccepted)
        pausedNs = Int64(clamping: t.pausedNanos)
        pauseCount = n(t.pauseCount)
        detokDelayFirstNs = ns(t.detokDelayFirstNanos)
        prefixLookupNs = ns(t.prefixLookupNanos)
        prefixAdoptionNs = ns(t.prefixAdoptionNanos)
        if let finishReason {
            self.finishReason = EngineFinishReason(reason: finishReason)
        }
    }
}

extension EngineFinishReason {
    /// Closed mapping from the engine's finish reason; every unknown or
    /// error-carrying case folds to a bounded value (never the error text).
    init(reason: CBv2FinishReason) {
        switch reason {
        case .stop: self = .stop
        case .length: self = .length
        case .cancelled: self = .cancelled
        case .error: self = .error
        default: self = .other
        }
    }
}
