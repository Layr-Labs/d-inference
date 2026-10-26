import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Paged KV for Qwen tensor parallel (owner rule: paged attention only for
/// KV): every request's full-attention keys and values on a rank (its own
/// key/value heads) live in fixed-size pages of one per-rank pool
/// (`PagedAttentionKVPool`), not in per-request `KVCacheSimple` buffers.
///
/// - A request reserves the pages of its prompt and one growth granule when
///   it starts (`reservePages`), and grows by granules between decode steps
///   while the live memory gate admits the slabs' growth (`growPages`; owner
///   rule 2026-10-22: no reservation for the whole context, no context cap).
///   A growth the gate refuses ends that request at its length (`length`),
///   both ranks after the same step (`QwenTensorParallelStopRule.lengthStop`).
///   The pool grows only between steps.
/// - Prefix entries share the request's pages (`copy`); a request restored
///   from one appends after them, copying only a shared partial page.
/// - Attention reads each history gathered from its pages into the same
///   `[1, kvHeads, offset, headDim]` arrays `KVCacheSimple` returns, so every
///   token and logit is the contiguous path's (`PagedAttentionKVCache`).
/// - The Gated DeltaNet layers' state is recurrent (no history) and stays as it was.
///
/// `DARKBLOOM_CLUSTER_QWEN_TP_PAGED_KV=0` keeps the contiguous caches, for an
/// A/B of the two on one build only; both ranks bind the choice into the
/// load agreement.
extension QwenTensorParallelResidentRuntime {
    /// Tokens per page.
    static let attentionPageTokens = 64

    static func pagedKV(_ environment: [String: String]) throws -> Bool {
        switch environment["DARKBLOOM_CLUSTER_QWEN_TP_PAGED_KV"] {
        case nil, "1": return true
        case "0": return false
        case let value?: throw ProbeError("DARKBLOOM_CLUSTER_QWEN_TP_PAGED_KV must be 0 or 1, not \(value)")
        }
    }

    static func pagedKVAgreementFields(_ paged: Bool) -> [String] {
        ["qwen-tp-paged-kv-v1", paged ? "page=\(attentionPageTokens)" : "contiguous"]
    }

    /// Pages one request of `tokens` tokens (prompt and outputs) holds at most
    /// on a rank: every attention layer's history.
    static func historyPages(pool: PagedAttentionKVPool, attentionLayers: Int, tokens: Int) -> Int {
        attentionLayers * pool.pages(tokens: tokens)
    }

    /// Tokens a request's pages grow by.
    static let pageGrowthTokens = 1024
    /// Tokens a request keeps reserved ahead of the step being built: a
    /// refused growth still covers the steps built before its stop reaches
    /// the peer (decode builds one step ahead).
    static let pageGrowthMargin = 64

    /// The tokens a request reserves at its start: its prompt and one granule,
    /// at most its whole length.
    static func initialPageTokens(promptCount: Int, maximumTokens: Int) -> Int {
        min(maximumTokens, promptCount + pageGrowthTokens)
    }

    /// Between steps: keeps `needed` tokens plus the margin reserved, growing
    /// by granules (up to `limit`, the request's whole length) when `admit`
    /// accepts what the slabs grow by. False when it does not (nothing
    /// changed): the request then ends at its length.
    static func growPages(_ pages: QwenTensorParallelPageReservation?, needed: Int, limit: Int, caches: [KVCache],
                          admit: (Int) throws -> Void) -> Bool {
        guard let pages, needed + pageGrowthMargin > pages.tokens, pages.tokens < limit else { return true }
        let target = min(limit, max(needed + pageGrowthMargin, pages.tokens + pageGrowthTokens))
        do {
            let bytes = pages.growthBytes(to: target)
            if bytes > 0 { try admit(bytes) }
            try pages.extend(to: target)
        } catch {
            return false
        }
        pages.bind(caches)
        return true
    }

    /// The host memory gate for `bytes` more, as the resident families take it.
    static func requireLiveMemory(bytes: Int) throws {
        try QwenResidentResourceEnvironment.require()
        let watch = QwenDenseStageLoadWatch("Qwen tensor-parallel")
        let os = try QwenDenseStageLoadResources.observeOS()
        let free = max(QwenDenseStageLoadPolicy.minimumAdmissibleBytes,
            try QwenLongPrefillCheckedBytes.sum([bytes, QwenDenseStageLoadPolicy.loadingHeadroomBytes]))
        guard try watch.admits(os, bytes: free) else {
            throw ProbeError("Qwen tensor parallel needs \(bytes) bytes the memory gate does not admit now")
        }
    }

    /// Memory the pool must add before it holds a request of `tokens` tokens:
    /// what the slabs grow by, plus the old slabs while they are copied into
    /// the new (the request's charge already holds its keys and values).
    static func pagedGrowthBytes(model: QwenTensorParallelModel?, tokens: Int) -> Int {
        guard let model, let pool = model.attentionPagePool else { return 0 }
        let growth = pool.growthBytes(reserving: historyPages(pool: pool,
            attentionLayers: model.attentionLayerCount, tokens: tokens))
        return growth > 0 ? growth + pool.capacityBytes : 0
    }

    /// Opens a request's page reservation for its first `tokens` (nil with
    /// contiguous caches). Between requests only: it may grow the pool.
    static func reservePages(model: QwenTensorParallelModel, tokens: Int) throws -> QwenTensorParallelPageReservation? {
        guard let pool = model.attentionPagePool else { return nil }
        // Pages released by the last request: every graph that read them was evaluated.
        pool.recycle()
        return try QwenTensorParallelPageReservation(pool: pool, attentionLayers: model.attentionLayerCount,
            tokens: tokens)
    }
}

/// A request's page reservation: `tokens` per attention history, opened for
/// the prompt and a granule and extended between steps (each extension is an
/// account of its own; the histories' new pages count against the latest).
/// Ended when the request's state goes (its pages that prefix entries still
/// hold stay with them).
final class QwenTensorParallelPageReservation {
    let pool: PagedAttentionKVPool
    let attentionLayers: Int
    private(set) var accounts: [GLM5NextDSAPageBook.Account] = []
    /// Tokens every attention history may hold under the open accounts.
    private(set) var tokens = 0
    /// The account the histories' new pages count against.
    var account: GLM5NextDSAPageBook.Account? { accounts.last }

    init(pool: PagedAttentionKVPool, attentionLayers: Int, tokens: Int) throws {
        self.pool = pool; self.attentionLayers = attentionLayers
        try extend(to: tokens)
    }

    /// Pages that holding `tokens` adds to the reservation.
    func addedPages(to tokens: Int) -> Int {
        max(0, attentionLayers * (pool.pages(tokens: tokens) - pool.pages(tokens: self.tokens)))
    }

    /// What the slabs grow by for that, plus the old slabs during the copy.
    func growthBytes(to tokens: Int) -> Int {
        let growth = pool.growthBytes(reserving: addedPages(to: tokens))
        return growth > 0 ? growth + pool.capacityBytes : 0
    }

    /// Reserves up to `tokens`. Between steps only: it may grow the pool.
    func extend(to tokens: Int) throws {
        guard tokens > self.tokens else { return }
        let pages = addedPages(to: tokens)
        if pages > 0 { accounts.append(try pool.reserve(pages: pages)) }
        self.tokens = tokens
    }

    /// Counts every paged history's new pages against the latest account.
    func bind(_ caches: [KVCache]) {
        guard let account else { return }
        for case let history as PagedAttentionKVCache in caches { history.account = account }
    }

    deinit { for account in accounts { pool.release(account) } }
}
