import DarkbloomClusterPlacement
import Foundation
import MLXLMCommon

/// One complete batch ledger, derived from the scalar TP canonical inventory.
/// Per-lane state is additive; retained fusion/constants, one prompt workspace,
/// the widest decode graph and encrypted transfer scratch are shared maxima.
/// Media/assistant state has a separate request-owned ledger and is not hidden
/// in this text trunk quote. Nothing here enables a model or a lane count.
/// A rank prices only its own heads and channels; nil prices the whole model
/// on either rank (`QwenTensorParallelRankLedger`).
struct QwenTensorParallelBatchBudget {
    let lanes: Int
    let perLaneStateBytes: Int
    let sharedBytesExcludingCollectives: Int
    let batchProjectionConstantBytes: Int
    let pagedPoolSlackBytes: Int
    /// Paged: one full-history gather bank, shared (one prompt frame per step).
    let promptGatherBytes: Int
    let prefix: QwenTensorParallelBatchPrefixBudget
    let allowance: ClusterTensorParallelRequestAllowance

    static func derive(geometry g: QwenLongPrefillBudgetGeometry, plan: QwenTensorParallelPlan,
                       tensors: [QwenDenseCanonicalTensor], maximumTokens: Int, chunkSize: Int,
                       lanes: Int, paged: Bool, rank: Int? = nil,
                       allocationBound: (Int) throws -> Int) throws -> Self {
        guard (1...8).contains(lanes) else {
            throw ProbeError("Qwen TP batch budget requires 1...8 lanes")
        }
        let scalar = try QwenTensorParallelRequestBudget.derive(geometry: g, plan: plan, tensors: tensors,
            maximumTokens: maximumTokens, chunkSize: chunkSize, rank: rank, allocationBound: allocationBound)
        let local = try g.tensorParallelShard(plan: plan, rank: rank)
        let sum = QwenLongPrefillCheckedBytes.sum, product = QwenLongPrefillCheckedBytes.product
        func bound(_ logical: Int, count: Int = 1) throws -> Int {
            let allocated = try allocationBound(logical)
            guard logical > 0, allocated >= logical, count >= 0 else { throw ProbeError("Invalid Qwen TP batch allocator bound") }
            return try product([allocated, count])
        }
        var perLaneState = scalar.stateBytes, poolSlack = 0, promptGather = 0
        if paged {
            // Restored prefixes copy into fresh request-owned pages. Each lane
            // holds one full page bank and a partial-page replacement per layer.
            // The full-history gather bank is a prompt frame's transient: decode
            // and verify windows attend the pages in place (the fused paged
            // decode kernel, one query column at a time), and the batch driver
            // runs at most one prompt frame per step, so one bank serves every
            // lane (`QwenTensorParallelBatchSessionTests.fullHistoryGatherIsOne
            // PromptFramesTransient` measures both). The scalar floor's F32 KV
            // term (two BF16 banks) is replaced by the lane's own BF16 page
            // bank and replacement; the gather bank moves to the shared charge.
            let page = CBv2PagedDefaults.pageSize, segment = CBv2StageKVHost.segmentBytes
            let roundedTokens = try product([(maximumTokens + page - 1) / page, page])
            let key = try product([roundedTokens, local.kvHeads, local.headDimension, 2])
            let bank = try bound(key, count: 2 * local.attentionLayers)
            let replacement = try bound(product([page, local.kvHeads, local.headDimension, 2]), count: 2 * local.attentionLayers)
            let oldKV = try bound(product([maximumTokens, local.kvHeads, local.headDimension, 4]), count: 2 * local.attentionLayers)
            guard scalar.stateBytes >= oldKV else { throw ProbeError("Qwen TP batch state lost its F32 KV floor") }
            perLaneState = try sum([scalar.stateBytes - oldKV, bank, replacement])
            promptGather = bank
            // The pool's segmented backing is shared. Account both its final
            // partially filled segment and its explicit spare segment, plus
            // allocator overhead on every possible committed segment. The
            // logical banks above already cover all occupied segment bytes.
            let logicalBank = try product([key, 2, local.attentionLayers])
            let poolCapacity = try sum([product([logicalBank, lanes]), segment])
            let segments = (poolCapacity + segment - 1) / segment
            let allocatedSegment = try bound(segment)
            poolSlack = try sum([product([allocatedSegment, 2]), product([segments, allocatedSegment - segment])])
        }
        // Row-M1 partials cause a second live FP32 scales/offsets bank while
        // singleton/prefill's ConstantArrayCastCache retains its first bank.
        // The rank's own columns of both banks, and prefix copies of its own
        // heads; without a rank, full canonical bytes cover either rank.
        let prefix = try QwenTensorParallelBatchPrefixBudget.derive(geometry: local,
            maximumTokens: maximumTokens, allocationBound: allocationBound)
        perLaneState = try sum([perLaneState, prefix.captureBytes])
        let batchConstants = scalar.projectionConstantBytes
        let logits = try bound(product([lanes, plan.vocabularySize, 4]), count: 3)
        let decodeTransient = try QwenResidentPrefillTransient.bytes(geometry: local,
            stageHasAttention: local.attentionLayers > 0, chunkTokens: 1, contextTokens: maximumTokens)
        let transient = max(scalar.transientBytes, decodeTransient == 0 ? 0 : try bound(decodeTransient, count: lanes))
        // A routed-expert layer's partial sources beside their one packed
        // collective (the collective scratch covers that payload): a prompt
        // chunk's (`QwenTensorParallelRequestBudget.packingBytes`), or a
        // decode cohort's, each lane's own. Zero for a dense plan.
        let packing = max(scalar.packingBytes, plan.routedExperts ? try sum([
            bound(product([plan.expertsPerToken, plan.hiddenSize, 4]), count: lanes),
            bound(product([plan.hiddenSize, 4]), count: lanes),
        ]) : 0)
        let shared = try sum([scalar.fusionBytes, transient, logits,
            scalar.projectionConstantBytes, batchConstants, poolSlack, prefix.residentBytes, packing, promptGather])
        // A one-token batch can gather more bytes than a short prompt frame.
        // Control limbs and retirement votes also travel in the sealed codec.
        let payload = max(scalar.allowance.maximumCollectivePayloadBytes,
            try product([lanes, plan.maximumPartialBytesPerToken]),
            try product([lanes, plan.vocabularySize, 4]),
            try product([QwenTensorParallelBatchWire.words, 4]))
        let frame = try sum([payload, QwenTensorParallelSealCodec.frameOverhead])
        let allowance = try ClusterTensorParallelRequestAllowance(maximumContextTokens: maximumTokens,
            maximumChunkTokens: chunkSize,
            requestBytesExcludingCollectives: sum([product([perLaneState, lanes]), shared]),
            maximumCollectivePayloadBytes: payload, maximumCollectiveFrameBytes: frame,
            allocationBound: allocationBound)
        return .init(lanes: lanes, perLaneStateBytes: perLaneState,
            sharedBytesExcludingCollectives: shared, batchProjectionConstantBytes: batchConstants,
            pagedPoolSlackBytes: poolSlack, promptGatherBytes: promptGather, prefix: prefix, allowance: allowance)
    }
}
