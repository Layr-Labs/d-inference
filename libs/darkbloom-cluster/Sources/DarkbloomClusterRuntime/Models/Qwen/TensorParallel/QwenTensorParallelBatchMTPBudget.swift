import DarkbloomClusterPlacement
import Foundation

/// Additive assistant ledger for a genuinely batched TP target. The assistant
/// parameters are resident once at LOAD. Each text lane may retain history
/// while its target joins a wider rectangle. Assistant draft calls are B=1;
/// optional multirow target verification charges retained cohort backings per
/// surviving lane plus a separate next-cohort workspace. With a rank, every
/// target term is that rank's own heads (`QwenTensorParallelRankLedger`).
struct QwenTensorParallelBatchMTPBudget {
    let target: QwenTensorParallelBatchBudget
    let assistantPerLaneBytes: Int
    let assistantSharedBytes: Int
    let assistantCarryBytes: Int
    let prefix: QwenTensorParallelMTPPrefixBudget
    let maximumSpeculativeWidth: Int
    let depth: Int
    let retainedCohortBytesPerLane: Int
    let cohortTransientBytes: Int
    let allowance: ClusterTensorParallelRequestAllowance

    let perLaneStateBytes: Int
    let sharedBytesExcludingCollectives: Int

    static func derive(geometry: QwenLongPrefillBudgetGeometry, plan: QwenTensorParallelPlan,
                       tensors: [QwenDenseCanonicalTensor], maximumTokens: Int, promptTokens: Int,
                       chunkSize: Int, lanes: Int, depth: Int, maximumSpeculativeWidth: Int = 1,
                       rank: Int? = nil, allocationBound: (Int) throws -> Int) throws -> Self {
        let sum = QwenLongPrefillCheckedBytes.sum, product = QwenLongPrefillCheckedBytes.product
        guard maximumSpeculativeWidth == 1 || maximumSpeculativeWidth == lanes else {
            throw ProbeError("Qwen TP assistant quote must cover its complete admitted cohort")
        }
        let target = try QwenTensorParallelBatchBudget.derive(geometry: geometry, plan: plan,
            tensors: tensors, maximumTokens: maximumTokens, chunkSize: chunkSize,
            lanes: lanes, paged: true, rank: rank, allocationBound: allocationBound)
        let local = try geometry.tensorParallelShard(plan: plan, rank: rank)
        // Every decode observation can leave a separately allocated one-token
        // root before this lane becomes singleton again. Ordinary observations
        // move the whole backlog into head K/V once it reaches the flush bound,
        // so the assistant supplement is the prompt's chunk roots plus at most
        // that many one-token roots, and first drafts run in bounded blocks.
        let full = try QwenTensorParallelMTPBudget.derive(geometry: geometry, plan: plan,
            tensors: tensors, maximumTokens: maximumTokens, promptTokens: promptTokens,
            chunkSize: min(chunkSize, promptTokens), depth: depth, rank: rank, allocationBound: allocationBound)
        // A carried hidden row is an exact view of its evaluated prompt,
        // decode rectangle or settled verify window. Preserve the arithmetic
        // and price the largest backing root per lane; each lane may retain a
        // different last-active rectangle while waiting for client credit.
        let windowRows = try product([maximumSpeculativeWidth, min(depth + 1, maximumTokens)])
        let carryRows = max(lanes, chunkSize, windowRows)
        let carrySource = try product([carryRows, geometry.hiddenSize, 2])
        let carryBytes = try allocationBound(carrySource)
        guard carryBytes >= carrySource else {
            throw ProbeError("Qwen TP assistant carry allocator bound is invalid")
        }
        func bound(_ logical: Int, count: Int = 1) throws -> Int {
            let allocated = try allocationBound(logical)
            guard logical > 0, allocated >= logical else { throw ProbeError("Qwen TP cohort allocator bound is invalid") }
            return try product([allocated, count])
        }
        var retainedCohort = 0, cohortTransient = 0
        if maximumSpeculativeWidth > 1 {
            let state = try QwenLongPrefillTensorBudget.estimate(geometry: local,
                maximumTokens: maximumTokens, chunkSize: chunkSize)
            // A committed row can retain the entire B*S captured backing even
            // after every other row retires. Charge that physical rectangle
            // per admitted survivor, separately from the next in-flight cohort.
            retainedCohort = try sum([
                bound(product([windowRows, state.convolutionBytesPerLayer]), count: geometry.recurrentLayers),
                bound(product([windowRows, state.ssmBytesPerLayer]), count: geometry.recurrentLayers),
                bound(product([windowRows, geometry.hiddenSize, 4]), count: 8),
                bound(product([windowRows, plan.vocabularySize, 4]), count: 4),
                bound(product([windowRows, 4]), count: 8),
            ])
            let one = try QwenResidentPrefillTransient.bytes(geometry: local,
                stageHasAttention: local.attentionLayers > 0,
                chunkTokens: min(depth + 1, maximumTokens), contextTokens: maximumTokens)
            cohortTransient = one == 0 ? 0 : try bound(product([one, maximumSpeculativeWidth]))
        }
        let perLane = try sum([full.assistantPageBytes, full.assistantGatherBytes,
            full.trustedHistoryBytes, full.prefix.captureBytes, carryBytes, retainedCohort])
        // Retain the existing complete target batch ledger. The additional
        // full target-page/gather supplement conservatively covers the one
        // captured window's COW/rollback bank; it is never used to reduce any
        // ordinary target state, prefix bank, pool slack or cast allowance.
        let shared: Int
        if maximumSpeculativeWidth == 1 {
            shared = try sum([full.promptWorkspaceBytes, full.capturedTargetBytes,
                full.targetPageSupplementBytes, full.windowBytes, full.prefix.residentBytes])
        } else {
            // Assistant calls remain eager B=1, so their large first-draft
            // workspace is shared once. All target windows coexist, including
            // retained prior cohorts while a new cohort verifies or rolls back.
            shared = try sum([full.promptWorkspaceBytes, retainedCohort, cohortTransient,
                product([full.targetPageSupplementBytes, maximumSpeculativeWidth]), full.prefix.residentBytes])
        }
        let laneTotal = try sum([target.perLaneStateBytes, perLane])
        let sharedTotal = try sum([target.sharedBytesExcludingCollectives, shared])
        let payload = max(target.allowance.maximumCollectivePayloadBytes,
            full.allowance.maximumCollectivePayloadBytes,
            try product([windowRows, plan.maximumPartialBytesPerToken]),
            try product([windowRows, plan.vocabularySize, 4]))
        let allowance = try ClusterTensorParallelRequestAllowance(maximumContextTokens: maximumTokens,
            maximumChunkTokens: chunkSize,
            requestBytesExcludingCollectives: sum([product([laneTotal, lanes]), sharedTotal]),
            maximumCollectivePayloadBytes: payload,
            maximumCollectiveFrameBytes: sum([payload, QwenTensorParallelSealCodec.frameOverhead]),
            allocationBound: allocationBound)
        return .init(target: target, assistantPerLaneBytes: perLane, assistantSharedBytes: shared,
            assistantCarryBytes: carryBytes,
            prefix: full.prefix, maximumSpeculativeWidth: maximumSpeculativeWidth, depth: depth,
            retainedCohortBytesPerLane: retainedCohort, cohortTransientBytes: cohortTransient,
            allowance: allowance,
            perLaneStateBytes: laneTotal, sharedBytesExcludingCollectives: sharedTotal)
    }
}
