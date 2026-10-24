import Foundation
import MLX

extension MiMoLayerStageSession: ClusterStagePrefixSession {
    func discardRestored(check: () throws -> Void) throws { try cancel() }
}

/// The shared two-exchange prefix plan (`agreeClusterStagePrefixPlan`) for a
/// MiMo stage: a restored or fresh `MiMoLayerStageSession`, and a capture of
/// its full-attention rows and sliding tails (`ClusterStagePrefixCapture.mimo`).
func agreeMiMoStagePrefixPlan(cache: QwenStagePrefixCache?, loaded: LoadedMiMoLayerStage, plan: MiMoLayerStagePlan,
    agreement: QwenLayerStageGenerationAgreement, collective: Collective, recordsSteps: Bool, independentHistory: Bool = false,
    check: () throws -> Void
) throws -> ClusterStagePrefixPlanOutcome<MiMoLayerStageSession> {
    guard !independentHistory || cache?.enabled != true else { throw ProbeError("Paged MiMo does not restore prefix state") }
    return try agreeClusterStagePrefixPlan(family: "mimo", cache: cache, agreement: agreement, collective: collective,
        check: check, restored: { planned, state in
            try MiMoLayerStageSession(stage: loaded, plan: plan, generationRequest: planned,
                recordsSteps: recordsSteps, restoring: state)
        }, fresh: { planned, _ in
            try MiMoLayerStageSession(stage: loaded, plan: plan, generationRequest: planned, recordsSteps: recordsSteps, independentHistory: independentHistory)
        }, capture: ClusterStagePrefixCapture.mimo)
}
