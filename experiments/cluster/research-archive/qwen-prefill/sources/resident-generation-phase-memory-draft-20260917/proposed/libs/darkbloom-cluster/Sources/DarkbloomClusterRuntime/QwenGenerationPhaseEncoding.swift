import Foundation

/// Closed report layout for real local CPU phase observations. This is not the
/// old loopback schema and does not assign wait time to the network or GPU.
enum QwenGenerationPhaseEncoding {
    static func encode(trace: QwenGenerationPhaseTrace, budget: QwenGenerationPhaseBudget,
                       execution: QwenLayerStageGenerationResult, memory: QwenResidentMemoryTrace, totalReserved: Int,
                       liveChecks: Int, into w: QwenGenerationPhaseJSON) throws {
        try w.raw("{"); try w.field("schema", "qwen_resident_generation_phase_memory_report_v1")
        try w.key("identity"); try identity(trace.identity, into: w); try w.raw(",")
        try w.field("clockSource", trace.clockSource)
        try w.field("protocolBoundary", trace.identity.protocolBoundary)
        try w.key("budget"); try w.raw("{")
        try w.number("maximumEvents", budget.maximumEvents)
        try w.number("eventLogicalBytes", budget.eventLogicalBytes)
        try w.number("eventAllocationBytes", budget.eventAllocationBytes)
        try w.number("memoryLogicalBytes", budget.memoryLogicalBytes)
        try w.number("memoryAllocationBytes", budget.memoryAllocationBytes)
        try w.number("encodedResultAllocationBytes", budget.encodedResultAllocationBytes)
        try w.number("encodingScratchAllowanceBytes", budget.encodingScratchAllowanceBytes)
        try w.number("metadataAllowanceBytes", budget.metadataAllowanceBytes)
        try w.number("requiredHostReservationBytes", budget.requiredHostReservationBytes)
        try w.number("totalReservedBytes", totalReserved, comma: false); try w.raw("},")
        try w.number("liveResourceChecksBeforeEncoding", liveChecks)
        try w.key("execution"); try w.raw("{")
        try w.number("completedFrames", execution.completedFrames)
        try w.number("committedTokens", execution.committedTokens)
        try w.field("tokenChainSHA256", execution.tokenChainSHA256)
        try w.field("finishReason", execution.finishReason.rawValue)
        try w.flag("bothRequestStatesRetired", execution.bothRequestStatesRetired)
        try w.key("selectedTokenIDs"); try w.raw("[")
        for (index, token) in execution.selectedTokenIDs.enumerated() {
            if index > 0 { try w.raw(",") }; try w.integer(token)
        }
        try w.raw("]},")
        try w.number("firstLocalUptimeNanoseconds", trace.firstLocalUptimeNanoseconds)
        try w.number("lastLocalUptimeNanoseconds", trace.lastLocalUptimeNanoseconds)
        try w.key("events"); try w.raw("[")
        for (index, event) in trace.events.enumerated() {
            if index > 0 { try w.raw(",") }; try encode(event, into: w)
        }
        try w.raw("],")
        try QwenResidentMemoryEncoding.encode(memory, into: w)
        try w.flag("diagnosticOnly", true)
        try w.flag("includesRecorderOverhead", true)
        try w.flag("mtpEnabled", false)
        try w.flag("modelRemainsResident", true)
        try w.flag("crossProcessClockAlignmentAsserted", false)
        try w.flag("gpuKernelTimeAsserted", false)
        try w.flag("transportWaitIsWireCost", false)
        try w.flag("ownerLeaseRetirementIndependentlyVerified", false)
        try w.flag("independentNumericalComparisonPerformed", false)
        try w.flag("wholeProcessPeakBoundProved", false, comma: false)
        try w.raw("}")
    }

    private static func identity(_ value: QwenGenerationPhaseIdentity, into w: QwenGenerationPhaseJSON) throws {
        try value.validate(); try w.raw("{")
        try w.field("requestID", value.requestID); try w.field("membershipEpoch", value.membershipEpoch)
        try w.field("requestFingerprint", value.requestFingerprint)
        try w.field("agreementFingerprint", value.agreementFingerprint)
        try w.field("profileFingerprint", value.profileFingerprint)
        try w.field("sourceConfigurationSHA256", value.sourceConfigurationSHA256)
        try w.field("artifactAggregateSHA256", value.artifactAggregateSHA256)
        try w.field("storageCommitmentSHA256", value.storageCommitmentSHA256)
        try w.field("planFingerprint", value.planFingerprint); try w.field("stageFingerprint", value.stageFingerprint)
        try w.field("buildSHA256", value.buildSHA256); try w.field("numericalPolicySHA256", value.numericalPolicySHA256)
        try w.number("rank", value.rank); try w.number("promptCount", value.promptCount)
        try w.number("chunkSize", value.chunkSize); try w.number("outputCount", value.outputCount)
        try w.field("prefillPolicy", value.prefillPolicy, comma: false); try w.raw("}")
    }

    private static func encode(_ event: QwenGenerationPhaseEvent, into w: QwenGenerationPhaseJSON) throws {
        let value = event.observation
        try w.raw("{"); try w.number("ordinal", event.ordinal)
        try w.number("localUptimeNanoseconds", event.localUptimeNanoseconds)
        try w.field("phase", value.phase.rawValue)
        try w.key("frame")
        if let frame = value.frame {
            try w.raw("{"); try w.number("sequence", frame.sequence); try w.number("tokenOffset", frame.tokenOffset)
            try w.number("tokenCount", frame.tokenCount); try w.flag("finalPromptChunk", frame.finalPromptChunk, comma: false)
            try w.raw("}")
        } else { try w.raw("null") }
        try w.raw(","); try w.optionalNumber("localCommittedTokens", value.localCommittedTokens)
        try w.optionalNumber("agreedCommittedTokens", value.agreedCommittedTokens, comma: false)
        try w.raw("}")
    }
}
