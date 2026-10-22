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

    /// Slab capacity an idle rank keeps for the next request
    /// (`DARKBLOOM_CLUSTER_GLM_PAGED_RETAIN_MB`, default 2,048 MB per rank,
    /// a ~100K-token request's pages). Above it, idle release trims as
    /// before, so memory drops after a long generation; at or below it the
    /// slabs stay and the next request reserves without allocating.
    static let defaultPagedRetainBytes = 2048 << 20

    static func pagedRetainBytes(_ environment: [String: String]) throws -> Int {
        guard let raw = environment["DARKBLOOM_CLUSTER_GLM_PAGED_RETAIN_MB"] else { return defaultPagedRetainBytes }
        guard let megabytes = Int(raw), (0...(1 << 30)).contains(megabytes) else {
            throw ProbeError("DARKBLOOM_CLUSTER_GLM_PAGED_RETAIN_MB must be a whole number of megabytes, not \(raw)")
        }
        return megabytes << 20
    }

    /// Whether idle release trims the slabs: under host pressure always,
    /// otherwise only when they hold more than `retainBytes`.
    static func trimsIdleSlabs(capacityBytes: Int, retainBytes: Int, underPressure: Bool) -> Bool {
        capacityBytes > 0 && (underPressure || capacityBytes > retainBytes)
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

    /// Tokens a request's pages grow by (owner rule 2026-10-22: no
    /// reservation for the whole output, grow on demand, no context cap; the
    /// same granule and margin as Qwen tensor parallel).
    static let pageGrowthTokens = 1024
    /// Tokens a request keeps reserved ahead of the step or round being
    /// built: a refused growth still covers the rounds built before its stop
    /// reaches the peer (decode builds one ahead).
    static let pageGrowthMargin = 64

    /// The context a request's pages cover at its start: its prompt and one
    /// granule, at most its whole length.
    static func initialPageTokens(promptCount: Int, maximumTokens: Int) -> Int {
        min(maximumTokens, promptCount + pageGrowthTokens)
    }

    /// The context a growth takes the pages to when `needed` context tokens
    /// plus the margin pass `tokens`: a granule on, or the margin past
    /// `needed`, never past `limit`; nil when no growth is due.
    static func pageGrowthTarget(tokens: Int, needed: Int, limit: Int) -> Int? {
        guard needed + pageGrowthMargin > tokens, tokens < limit else { return nil }
        return min(limit, max(needed + pageGrowthMargin, tokens + pageGrowthTokens))
    }

    /// Memory the pool must add before it holds `request`'s pages at
    /// `context` (default: its whole maximum), beyond the pages its charge
    /// already holds (`GLM5NextTensorParallelRequestCharge.pagedHistoryBytes`):
    /// what the slabs grow by past them (growth is in 1.5x granules), plus
    /// the old slabs while they are copied into the new.
    func pagedGrowthBytes(_ request: QwenLayerStageGenerationRequest, context: Int? = nil) -> Int {
        guard let pool = stage?.dsaPagePool else { return 0 }
        let pages = Self.historyPages(pool: pool, configuration: descriptor.configuration.textConfig,
            contextTokens: requestCharge.historyTokens(contextTokens: context ?? request.maximumTokens),
            speculative: mtp != nil)
        let growth = pool.growthBytes(reserving: pages)
        return growth > 0 ? max(0, growth - pages * pool.pageBytes) + pool.capacityBytes : 0
    }

    /// Between steps or rounds: keeps `needed` context tokens plus the
    /// margin reserved in every history (DSA layers and NextN), growing by
    /// granules up to the request's length when the live memory gate admits
    /// what the slabs grow by (the admission charge already holds the pages
    /// themselves). False when it does not (nothing changed): the request
    /// then ends at its length (`QwenTensorParallelStopRule.lengthStop`).
    func growPages(_ pages: GLM5NextPageReservation?, needed: Int, limit: Int) -> Bool {
        guard let pages, let tokens = pages.tokens,
              let target = Self.pageGrowthTarget(tokens: tokens, needed: needed, limit: limit) else { return true }
        let c = descriptor.configuration.textConfig, pool = pages.pool
        func historyPages(_ context: Int) -> Int {
            Self.historyPages(pool: pool, configuration: c,
                contextTokens: requestCharge.historyTokens(contextTokens: context), speculative: mtp != nil)
        }
        let add = historyPages(target) - historyPages(tokens)
        do {
            let growth = pool.growthBytes(reserving: add)
            if growth > 0 {
                try yieldingIdleMemory { try Self.requireLiveMemory(bytes: growth + pool.capacityBytes) }
            }
            try pool.extend(pages.account, by: add)
        } catch {
            return false
        }
        pages.tokens = target; pages.grown += 1
        return true
    }

    /// What an idle rank keeps for the next request gives way before a gate
    /// refuses: MLX's freed buffers and the prompt-prefix entries
    /// (`prefix.yieldingMemory`), then the page slabs it retains between
    /// requests (`releaseIdleMemory`), whole once no entry holds a page. A
    /// trim is a no-op while any request or lane holds pages.
    func yieldingIdleMemory<T>(_ body: () throws -> T) throws -> T {
        do { return try prefix.yieldingMemory(body) } catch {
            guard let pool = stage?.dsaPagePool, ((try? pool.trim()) ?? 0) > 0 else { throw error }
            Memory.clearCache()
            return try body()
        }
    }

    /// Opens `request`'s page reservation (nil with contiguous histories):
    /// a growing request's prompt and one granule (`growPages` extends it),
    /// else its whole length (lanes). Between steps only: it may grow the pool.
    func reservePages(_ request: QwenLayerStageGenerationRequest, growing: Bool = false) throws
        -> GLM5NextPageReservation? {
        guard let pool = stage?.dsaPagePool else { return nil }
        // Pages released by the last steps: every graph that read them was submitted.
        pool.recycle()
        let context = growing ? Self.initialPageTokens(promptCount: request.promptTokenIDs.count,
            maximumTokens: request.maximumTokens) : request.maximumTokens
        let pages = Self.historyPages(pool: pool, configuration: descriptor.configuration.textConfig,
            contextTokens: requestCharge.historyTokens(contextTokens: context), speculative: mtp != nil)
        let reservation = GLM5NextPageReservation(pool: pool, account: try pool.reserve(pages: pages))
        if growing { reservation.tokens = context }
        return reservation
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
    /// A growing request's context its pages cover (nil: its whole length
    /// was reserved at open), and how often they grew.
    var tokens: Int?
    var grown = 0

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
