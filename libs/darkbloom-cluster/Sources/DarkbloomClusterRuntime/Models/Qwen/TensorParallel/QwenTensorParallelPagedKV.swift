import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Paged KV for Qwen tensor parallel (owner rule: paged attention only for
/// KV): every request's full-attention keys and values on a rank (its own
/// key/value heads) live in fixed-size pages of one per-rank pool
/// (`PagedAttentionKVPool`), not in per-request `KVCacheSimple` buffers.
///
/// - A request reserves its pages when it starts (`reservePages`): every
///   attention layer's history at the request's own length, plus the page a
///   copy on write holds beside each. The pool grows only there, between
///   requests.
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

    /// Memory the pool must add before it holds a request of `tokens` tokens:
    /// what the slabs grow by, plus the old slabs while they are copied into
    /// the new (the request's charge already holds its keys and values).
    static func pagedGrowthBytes(model: QwenTensorParallelModel?, tokens: Int) -> Int {
        guard let model, let pool = model.attentionPagePool else { return 0 }
        let growth = pool.growthBytes(reserving: historyPages(pool: pool,
            attentionLayers: model.attentionLayerCount, tokens: tokens))
        return growth > 0 ? growth + pool.capacityBytes : 0
    }

    /// Opens a request's page reservation (nil with contiguous caches).
    /// Between requests only: it may grow the pool.
    static func reservePages(model: QwenTensorParallelModel, tokens: Int) throws -> QwenTensorParallelPageReservation? {
        guard let pool = model.attentionPagePool else { return nil }
        // Pages released by the last request: every graph that read them was evaluated.
        pool.recycle()
        return QwenTensorParallelPageReservation(pool: pool, account: try pool.reserve(pages:
            historyPages(pool: pool, attentionLayers: model.attentionLayerCount, tokens: tokens)))
    }
}

/// A request's page reservation, ended when the request's state goes (its
/// pages that prefix entries still hold stay with them).
final class QwenTensorParallelPageReservation {
    let pool: PagedAttentionKVPool
    let account: GLM5NextDSAPageBook.Account

    init(pool: PagedAttentionKVPool, account: GLM5NextDSAPageBook.Account) {
        self.pool = pool; self.account = account
    }

    deinit { pool.release(account) }
}
