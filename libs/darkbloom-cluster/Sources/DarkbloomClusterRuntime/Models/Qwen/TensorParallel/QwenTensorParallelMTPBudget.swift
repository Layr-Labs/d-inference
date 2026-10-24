import DarkbloomClusterPlacement
import Foundation

/// Additional storage for the exact one-layer Qwen27 assistant and captured
/// target windows. The unchanged full target ledger remains charged. Loaded
/// assistant weights and constructor peak are separate resident/LOAD charges.
/// The replicated assistant is priced whole on every rank; with a rank, the
/// target's terms are that rank's own heads (`QwenTensorParallelRankLedger`).
struct QwenTensorParallelMTPBudget {
    let assistantPageBytes: Int
    let assistantGatherBytes: Int
    let trustedHistoryBytes: Int
    let promptWorkspaceBytes: Int
    let capturedTargetBytes: Int
    let targetPageSupplementBytes: Int
    let windowBytes: Int
    let prefix: QwenTensorParallelMTPPrefixBudget
    let allowance: ClusterTensorParallelRequestAllowance

    static func derive(geometry g: QwenLongPrefillBudgetGeometry, plan: QwenTensorParallelPlan,
                       tensors: [QwenDenseCanonicalTensor], maximumTokens: Int, promptTokens: Int,
                       chunkSize: Int, depth: Int,
                       flushRows: Int? = QwenTensorParallelMTPPolicy.historyFlushRows, rank: Int? = nil,
                       allocationBound: (Int) throws -> Int) throws -> Self {
        let sum = QwenLongPrefillCheckedBytes.sum, product = QwenLongPrefillCheckedBytes.product
        guard g.hiddenSize == 5120, g.layers == 64, g.queryHeads == 24, g.kvHeads == 4,
              g.headDimension == 256, g.attentionLayers == 16, g.recurrentLayers == 48,
              g.linearKeyHeads == 16, g.linearValueHeads == 48,
              g.linearKeyDimension == 128, g.linearValueDimension == 128,
              plan.vocabularySize == 248320, !plan.routedExperts,
              (1...4).contains(depth), (1...(1 << 20)).contains(maximumTokens),
              promptTokens > 0, promptTokens <= maximumTokens,
              chunkSize > 0, chunkSize <= maximumTokens,
              flushRows.map({ $0 > 0 }) ?? true else {
            throw ProbeError("Qwen TP MTP budget requires its exact registered one-layer geometry")
        }
        func bound(_ bytes: Int, count: Int = 1) throws -> Int {
            let allocated = try allocationBound(bytes)
            guard bytes > 0, allocated >= bytes, count >= 0 else {
                throw ProbeError("Qwen TP MTP allocator bound is invalid")
            }
            return try product([allocated, count])
        }
        let executionChunk = max(chunkSize, min(depth + 1, maximumTokens))
        let base = try QwenTensorParallelRequestBudget.derive(geometry: g, plan: plan, tensors: tensors,
            maximumTokens: maximumTokens, chunkSize: executionChunk, rank: rank, allocationBound: allocationBound)
        let local = try g.tensorParallelShard(plan: plan, rank: rank)
        let target = try QwenLongPrefillTensorBudget.estimate(geometry: local,
            maximumTokens: maximumTokens, chunkSize: chunkSize)
        let width = depth + 1, pages = (maximumTokens + 63) / 64
        let kvWidth = try product([g.kvHeads, g.headDimension])
        let page = try product([64, kvWidth, 2])
        let assistantPages = try bound(page, count: 2 * pages)
        // Chronological K/V gathers and replacement banks during COW writes;
        // each array is rounded separately, including the partial tail pages.
        let assistantGather = try sum([bound(product([maximumTokens, kvWidth, 2]), count: 4), bound(page, count: 4)])
        // Trusted target rows remain as original per-chunk roots while a full
        // prompt feed is concatenated for the first draft. Charge each source
        // root's allocator bound, plus the full normalized/copy banks. No
        // assumption that prompt history is bounded by the final chunk. With
        // bounded flushes, ordinary decode leaves at most `flushRows`
        // one-token roots before the whole backlog moves into head K/V.
        let chunks = (promptTokens + chunkSize - 1) / chunkSize
        let decodeRoots = min(flushRows ?? 0, maximumTokens)
        let banked = min(maximumTokens, promptTokens + decodeRoots)
        let history = try sum([
            bound(product([min(promptTokens, chunkSize), g.hiddenSize, 2]), count: 2 * chunks),
            bound(product([min(promptTokens, chunkSize), 4]), count: 2 * chunks),
            bound(product([g.hiddenSize, 2]), count: 2 * decodeRoots), bound(4, count: 2 * decodeRoots),
            bound(product([banked, g.hiddenSize, 2]), count: 3),
            bound(product([banked, 4]), count: 3), bound(product([g.hiddenSize, 2]), count: 4),
        ])
        // The first draft appends all trusted history through embedding,
        // pre-FC norms, the 2H concatenation/FC, input norm and K/V-only
        // attention, conservatively pricing FP32 intermediates even though
        // registered activations are BF16. Bounded flushes evaluate leading
        // history in `flushRows` blocks, leaving at most one block plus the
        // proposal row; without them the whole history is one rectangle.
        // Full MLP/query attention is only run for the final proposal row.
        let rectangle = flushRows.map { $0 >= promptTokens ? promptTokens : $0 + 1 } ?? promptTokens
        let promptWorkspace = try sum([
            bound(product([rectangle, g.hiddenSize, 4]), count: 16),
            bound(product([rectangle, 2, g.hiddenSize, 4]), count: 2),
            bound(product([rectangle, kvWidth, 4]), count: 12),
            bound(product([rectangle, g.hiddenSize / 8, 4])),
            bound(product([rectangle, g.hiddenSize / 64, 4]), count: 2),
            bound(product([width, 17_408, 4]), count: 8),
            bound(product([width, g.queryHeads, maximumTokens, 4]), count: 2),
        ])
        let captured = try sum([
            bound(target.convolutionBytesPerLayer, count: width * g.recurrentLayers),
            bound(target.ssmBytesPerLayer, count: width * g.recurrentLayers),
        ])
        // A captured window writes its columns into the row's own pages and
        // rolls back by moving the row frontier (PagedSequenceKV.rollback only
        // releases whole pages; nothing is copied). Its attention gathers each
        // layer once, a transient the target ledger's full-history gather bank
        // already prices for every layer at once. The window adds partial-page
        // replacements across a page boundary and allocator segment slack,
        // at the rank's own heads (full heads without a rank). Measured on
        // paged CBv2 by
        // QwenTensorParallelMTPSessionTests.capturedWindowsAllocateNoSecondHistory.
        let targetPage = try product([64, local.kvHeads, local.headDimension, 2])
        let targetPages = try sum([
            bound(targetPage, count: 4 * local.attentionLayers),
            product([2, CBv2StageKVHost.segmentBytes]),
        ])
        let window = try sum([
            bound(product([width, plan.vocabularySize, 4]), count: 4),
            bound(product([width, g.hiddenSize, 4]), count: 8),
            bound(product([width, 4]), count: 8),
        ])
        // The target capture is the rank's own heads; the assistant's is hidden-wide.
        let prefix = try QwenTensorParallelMTPPrefixBudget.derive(geometry: local,
            maximumTokens: maximumTokens, allocationBound: allocationBound)
        let extra = try sum([assistantPages, assistantGather, history, promptWorkspace, captured, targetPages, window,
                             prefix.captureBytes, prefix.residentBytes])
        let payload = max(base.allowance.maximumCollectivePayloadBytes,
            try product([width, plan.maximumPartialBytesPerToken]), try product([width, plan.vocabularySize, 4]))
        let allowance = try ClusterTensorParallelRequestAllowance(maximumContextTokens: maximumTokens,
            maximumChunkTokens: chunkSize,
            requestBytesExcludingCollectives: sum([base.allowance.requestBytesExcludingCollectives, extra]),
            maximumCollectivePayloadBytes: payload,
            maximumCollectiveFrameBytes: sum([payload, QwenTensorParallelSealCodec.frameOverhead]),
            allocationBound: allocationBound)
        return .init(assistantPageBytes: assistantPages, assistantGatherBytes: assistantGather,
            trustedHistoryBytes: history, promptWorkspaceBytes: promptWorkspace, capturedTargetBytes: captured,
            targetPageSupplementBytes: targetPages, windowBytes: window, prefix: prefix, allowance: allowance)
    }
}
