import Foundation
import MLX
import MLXLLM

/// Paged KV for GLM tensor parallel: every request's DSA histories (each DSA
/// layer's latents, index keys, pool gates and validity, replicated on both
/// ranks) and its NextN history live in fixed-size pages of one per-rank pool
/// (`GLM5NextDSAPagePool`), not in per-request contiguous buffers.
///
/// - A request reserves its pages when it opens (`reserve`): every DSA layer's
///   and the NextN layer's history at its own context (prompt, outputs and a
///   verification window), plus the page a copy on write holds beside each
///   until its step commits. The pool grows only there, between steps.
/// - Prefix entries share the request's pages (no copy); a request restored
///   from one appends after them, copying only a shared partial page.
/// - An MTP round's rejected tokens drop their pages at the round's commit.
/// - Attention reads each history gathered from its pages into the same
///   contiguous arrays the contiguous cache holds, so every token and logit
///   is the contiguous path's (`GLM5NextDSACache`).
///
/// `DARKBLOOM_CLUSTER_GLM_PAGED_KV=0` keeps the contiguous histories, for an
/// A/B of the two on one build only; both ranks bind the choice into the load
/// agreement.
extension GLM5NextTensorParallelResidentRuntime {
    /// Tokens per page.
    static let dsaPageTokens = GLM5NextPageReservation.pageTokens

    static func pagedKV(_ environment: [String: String]) throws -> Bool {
        switch environment["DARKBLOOM_CLUSTER_GLM_PAGED_KV"] {
        case nil, "1": return true
        case "0": return false
        case let value?: throw ProbeError("DARKBLOOM_CLUSTER_GLM_PAGED_KV must be 0 or 1, not \(value)")
        }
    }

    static func pagedKVAgreementFields(_ paged: Bool) -> [String] {
        ["glm5-next-tp-paged-kv-v1", paged ? "page=\(dsaPageTokens)" : "contiguous"]
    }

    /// Pages one request holds at most on a rank: every DSA layer's history
    /// and, when it speculates, the NextN history, each at `contextTokens`
    /// (`GLM5NextDSAPagePool.pages(tokens:)`).
    static func historyPages(pool: GLM5NextDSAPagePool, configuration c: GLM5NextTextConfiguration,
                             contextTokens: Int, speculative: Bool) -> Int {
        let layers = c.layerTypes.filter { $0 == .deepseekSparseAttention }.count + (speculative ? 1 : 0)
        return layers * pool.pages(tokens: contextTokens)
    }

    /// The longest history a request may write: its prompt and outputs, and
    /// the verification window past its last output.
    static func historyTokens(_ request: QwenLayerStageGenerationRequest) -> Int {
        request.promptTokenIDs.count + request.outputCount + mtpDepth + 1
    }

    /// Memory the pool must add before it holds `request`'s pages, beyond
    /// the pages its charge already holds (`GLM5NextTensorParallelRequestCharge.pagedHistoryBytes`):
    /// what the slabs grow by past them (growth is in 1.5x granules), plus
    /// the old slabs while they are copied into the new.
    func pagedGrowthBytes(_ request: QwenLayerStageGenerationRequest) -> Int {
        guard let pool = stage?.dsaPagePool else { return 0 }
        let pages = Self.historyPages(pool: pool, configuration: descriptor.configuration.textConfig,
            contextTokens: Self.historyTokens(request), speculative: mtp != nil)
        let growth = pool.growthBytes(reserving: pages)
        return growth > 0 ? max(0, growth - pages * pool.pageBytes) + pool.capacityBytes : 0
    }

    /// Opens `request`'s page reservation (nil with contiguous histories).
    /// Between steps only: it may grow the pool.
    func reservePages(_ request: QwenLayerStageGenerationRequest) throws -> GLM5NextPageReservation? {
        guard let pool = stage?.dsaPagePool else { return nil }
        // Pages released by the last steps: every graph that read them was submitted.
        pool.recycle()
        let pages = Self.historyPages(pool: pool, configuration: descriptor.configuration.textConfig,
            contextTokens: Self.historyTokens(request), speculative: mtp != nil)
        return GLM5NextPageReservation(pool: pool, account: try pool.reserve(pages: pages))
    }
}

/// A request's page reservation, ended when the request's state goes (its
/// pages that prefix entries still hold stay with them). Tensor parallel and
/// pipeline GLM stages alike.
final class GLM5NextPageReservation {
    /// Tokens per page.
    static let pageTokens = 64

    let pool: GLM5NextDSAPagePool
    let account: GLM5NextDSAPageBook.Account

    /// The activation type a stage without the embedding receives (its
    /// boundary's, the configuration's `dtype`).
    static func activationType(_ stage: GLM5NextTextStage) throws -> DType {
        switch stage.plan.configuration.dtype {
        case "bfloat16": return .bfloat16
        case "float16": return .float16
        case "float32": return .float32
        case let other: throw ProbeError("GLM stage activation type \(other) has no paged history")
        }
    }

    init(pool: GLM5NextDSAPagePool, account: GLM5NextDSAPageBook.Account) {
        self.pool = pool; self.account = account
    }

    deinit { pool.release(account) }
}
