import MLXLMCommon

extension MTPBenchmarkMetrics {
    /// Project only metrics the engine actually exposes. Assistant/target
    /// timing stays nil rather than being estimated from aggregate wall time.
    public init(engineMetrics value: CBv2MTPMetrics) {
        self.init(
            active: value.active,
            verificationMode: value.verificationMode.rawValue,
            maxAutomaticRectangularTokens: value.maxAutomaticRectangularTokens,
            rectangularVerificationRounds: value.rectangularVerificationRounds,
            serialVerificationRounds: value.serialVerificationRounds,
            selectedDepth: value.selectedDepth,
            decodeRowBucket: value.decodeRowBucket,
            rounds: value.rounds,
            seedRows: value.seedSteps,
            proposedTokens: value.proposedTokens,
            acceptedDraftTokens: value.acceptedTokens,
            committedTokens: value.emittedTokens,
            acceptanceByPosition: value.perPositionAccepted,
            conditionalAcceptance: value.conditionalAcceptance,
            skippedRows: value.skippedRows,
            depthSelections: Dictionary(
                uniqueKeysWithValues: value.depthSelections.map { (String($0.key), $0.value) }),
            controllerFallbacks: value.controllerFallbacks,
            costInputs: value.costInputs.map {
                CostInput(
                    decodeRowBucket: $0.decodeRowBucket,
                    draftDepth: $0.depth,
                    sampleCount: $0.samples,
                    ewmaRoundWallTimeNanos: $0.ewmaWallTimeNanos,
                    totalRoundWallTimeNanos: $0.totalWallTimeNanos)
            },
            totalRoundWallTimeNanos: value.totalRoundWallTimeNanos,
            // Host timestamps the engine already took; projecting them costs
            // nothing and is what makes a per-stage round regression visible
            // in the report instead of inferable from round deltas.
            roundTiming: value.roundTiming.rounds > 0
                ? MTPBenchmarkRoundTiming(
                    rounds: value.roundTiming.rounds,
                    hostGapNanos: value.roundTiming.hostGapNanos,
                    captureNanos: value.roundTiming.captureNanos,
                    draftBuildNanos: value.roundTiming.draftBuildNanos,
                    verifyBuildNanos: value.roundTiming.verifyBuildNanos,
                    submitNanos: value.roundTiming.submitNanos,
                    packetWaitNanos: value.roundTiming.packetWaitNanos,
                    acceptWalkNanos: value.roundTiming.acceptWalkNanos,
                    rowFinalizeNanos: value.roundTiming.rowFinalizeNanos,
                    minRoundNanos: value.roundTiming.minRoundNanos,
                    maxRoundNanos: value.roundTiming.maxRoundNanos)
                : nil)
    }
}

public enum MTPBenchmarkEngineMetrics {
    public static func snapshot(engine: any CBv2Engine) -> MTPBenchmarkMetrics {
        guard let engine = engine as? EngineV2 else { return .inactive }
        guard let metrics = engine.mtpMetricsSnapshot() else {
            return MTPBenchmarkMetrics(
                active: false,
                inactiveReason: engine.mtpInactiveReason)
        }
        return MTPBenchmarkMetrics(engineMetrics: metrics)
    }
}
