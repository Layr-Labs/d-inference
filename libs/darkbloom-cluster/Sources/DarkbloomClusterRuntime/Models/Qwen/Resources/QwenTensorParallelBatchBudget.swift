import DarkbloomClusterPlacement
import Foundation
import MLXLMCommon

/// One complete batch ledger, derived from the scalar TP canonical inventory.
/// Per-lane state is additive; retained fusion/constants, one prompt workspace,
/// the widest decode graph and encrypted transfer scratch are shared maxima.
/// Media/assistant state has a separate request-owned ledger and is not hidden
/// in this text trunk quote. Nothing here enables a model or a lane count.
struct QwenTensorParallelBatchBudget {
    let lanes: Int
    let perLaneStateBytes: Int
    let sharedBytesExcludingCollectives: Int
    let batchProjectionConstantBytes: Int
    let pagedPoolSlackBytes: Int
    let prefix: QwenTensorParallelBatchPrefixBudget
    let allowance: ClusterTensorParallelRequestAllowance

    static func derive(geometry g: QwenLongPrefillBudgetGeometry, plan: QwenTensorParallelPlan,
                       tensors: [QwenDenseCanonicalTensor], maximumTokens: Int, chunkSize: Int,
                       lanes: Int, paged: Bool, allocationBound: (Int) throws -> Int) throws -> Self {
        guard (2...8).contains(lanes), !plan.routedExperts else {
            throw ProbeError("Qwen TP batch budget requires 2...8 dense-model lanes")
        }
        let scalar = try QwenTensorParallelRequestBudget.derive(geometry: g, plan: plan,
            tensors: tensors, maximumTokens: maximumTokens, chunkSize: chunkSize, allocationBound: allocationBound)
        let sum = QwenLongPrefillCheckedBytes.sum, product = QwenLongPrefillCheckedBytes.product
        func bound(_ logical: Int, count: Int = 1) throws -> Int {
            let allocated = try allocationBound(logical)
            guard logical > 0, allocated >= logical, count >= 0 else { throw ProbeError("Invalid Qwen TP batch allocator bound") }
            return try product([allocated, count])
        }
        var perLaneState = scalar.stateBytes, poolSlack = 0
        if paged {
            // Restored prefixes copy into fresh request-owned pages. Reserve one
            // full page bank, a full-history gather bank and a partial-page
            // replacement per layer. Replace, never add again, the existing
            // F32 KV term (two BF16 banks) in the conservative scalar floor.
            let page = CBv2PagedDefaults.pageSize, segment = CBv2StageKVHost.segmentBytes
            let roundedTokens = try product([(maximumTokens + page - 1) / page, page])
            let key = try product([roundedTokens, g.kvHeads, g.headDimension, 2])
            let bank = try bound(key, count: 2 * g.attentionLayers)
            let replacement = try bound(product([page, g.kvHeads, g.headDimension, 2]), count: 2 * g.attentionLayers)
            let oldKV = try bound(product([maximumTokens, g.kvHeads, g.headDimension, 4]), count: 2 * g.attentionLayers)
            let actualKV = try sum([product([bank, 2]), replacement])
            perLaneState = try sum([scalar.stateBytes, max(0, actualKV - oldKV)])
            // The pool's segmented backing is shared. Account both its final
            // partially filled segment and its explicit spare segment, plus
            // allocator overhead on every possible committed segment. The
            // logical banks above already cover all occupied segment bytes.
            let logicalBank = try product([key, 2, g.attentionLayers])
            let poolCapacity = try sum([product([logicalBank, lanes]), segment])
            let segments = (poolCapacity + segment - 1) / segment
            let allocatedSegment = try bound(segment)
            poolSlack = try sum([product([allocatedSegment, 2]), product([segments, allocatedSegment - segment])])
        }
        // Row-M1 partials cause a second live FP32 scales/offsets bank while
        // singleton/prefill's ConstantArrayCastCache retains its first bank.
        // Full canonical bytes cover either rank, including unequal shares.
        let prefix = try QwenTensorParallelBatchPrefixBudget.derive(geometry: g,
            maximumTokens: maximumTokens, allocationBound: allocationBound)
        perLaneState = try sum([perLaneState, prefix.captureBytes])
        let batchConstants = scalar.projectionConstantBytes
        let logits = try bound(product([lanes, plan.vocabularySize, 4]), count: 3)
        let decodeTransient = try QwenResidentPrefillTransient.bytes(geometry: g,
            stageHasAttention: g.attentionLayers > 0, chunkTokens: 1, contextTokens: maximumTokens)
        let transient = max(scalar.transientBytes, decodeTransient == 0 ? 0 : try bound(decodeTransient, count: lanes))
        let shared = try sum([scalar.fusionBytes, transient, logits,
            scalar.projectionConstantBytes, batchConstants, poolSlack, prefix.residentBytes])
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
            pagedPoolSlackBytes: poolSlack, prefix: prefix, allowance: allowance)
    }
}
