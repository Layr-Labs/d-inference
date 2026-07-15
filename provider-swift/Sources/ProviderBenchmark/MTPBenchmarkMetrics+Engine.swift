import MLXLMCommon

extension MTPBenchmarkMetrics {
    /// Project only metrics the engine actually exposes. Assistant/target
    /// timing stays nil rather than being estimated from aggregate wall time.
    public init(engineMetrics value: CBv2MTPMetrics) {
        self.init(
            active: value.active,
            verificationMode: value.verificationMode.rawValue,
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
            totalRoundWallTimeNanos: value.totalRoundWallTimeNanos)
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
