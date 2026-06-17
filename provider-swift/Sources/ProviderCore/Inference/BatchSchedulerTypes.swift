// Copyright © 2026 Eigen Labs.
//
// Supporting types for `BatchScheduler` and its extensions.
//
// `GenerationEvent` and `SchedulerCapacity` are the public types the
// scheduler exposes to callers (ProviderLoop / StandaloneServer).
//
// `BridgeState`, `PendingSummary`, `LoadSnapshot`, `ModelArchitecture`
// and `TokenizerHandle` are scheduler-internal — kept `internal` (not
// `private`) so the bridge / KV-estimation / telemetry extensions can
// see them across files.

import Foundation
import MLXLMCommon

// MARK: - Public surface

/// Events emitted by the scheduler for a single inference request.
public enum GenerationEvent: Sendable {
    case chunk(String)
    case info(promptTokens: Int, completionTokens: Int, tokensPerSecond: Double)
    case error(String)
}

/// Snapshot of the scheduler's capacity, reported to the coordinator in heartbeats.
public struct SchedulerCapacity: Sendable {
    public let model: String
    public let activeRequests: Int
    public let pendingRequests: Int
    public let maxConcurrent: Int
    public let engineMaxConcurrent: Int
    public let gpuMemoryActiveBytes: Int
    public let gpuMemoryPeakBytes: Int
    public let gpuMemoryCacheBytes: Int
    public let totalMemoryBytes: UInt64
}

// MARK: - Internal scheduler-bookkeeping types
//
// Promoted from `private` to `internal` so `BatchScheduler+EngineBridge.swift`
// and `BatchScheduler+Telemetry.swift` can read/mutate them.

/// Per-request bookkeeping driven by the per-request streaming Task.
///
/// `admittedAt` is set on the first `RequestOutput` the engine emits
/// for the request (distinguishing "queued in engine pending list" from
/// "running on the GPU"). The pending-timeout watchdog uses this to
/// avoid aborting long prefills as queue timeouts.
struct BridgeState {
    let requestId: String
    var promptTokens: Int
    var completionTokens: Int = 0
    let maxTokens: Int
    /// Memory-admission budget for this request. Normally this is
    /// `promptTokens + maxTokens`; restored checkpoint hits can require a larger
    /// reservation because the provider materializes restored KV before handing
    /// it to MLX, and MLX then builds a batched copy for decode.
    var reservedTokens: Int? = nil
    /// Prefix tokens whose KV was restored from the checkpoint cache (0 on a cold
    /// prefill). The admitted→first-token window only covers prefilling the
    /// UNCACHED suffix, so `recordFinish` subtracts this from the prompt length
    /// before updating the prefill-rate EWMA — otherwise a cache hit would inflate
    /// `observed_prefill_tps` far above the true cold-prefill rate (which
    /// routing-v2 consumes for TTFT estimates).
    var restoredPrefixTokens: Int = 0
    let submittedAt: ContinuousClock.Instant
    var admittedAt: ContinuousClock.Instant?
    var firstTokenAt: ContinuousClock.Instant?
    var lastTokenAt: ContinuousClock.Instant?
}

/// Cached pending-queue stats, refreshed via `refreshPendingSummaryCache`.
///
/// We cache so `backendCapacity()` doesn't call into the planner actor
/// on every heartbeat (which would serialize against admit/cancel).
struct PendingSummary {
    let queuedRequests: Int
    let queuedTokens: Int

    static let empty = PendingSummary(queuedRequests: 0, queuedTokens: 0)
}

/// Snapshot returned from the `container.perform { ... }` closure in
/// `loadModel`. Carries everything the actor needs to wire up the
/// engine + KV-budget without re-entering the container.
struct LoadSnapshot: @unchecked Sendable {
    let bytes: Int
    let tokenizer: TokenizerHandle
    let eosTokenIds: Set<Int>
    let architecture: ModelArchitecture
}

/// Sendable summary of the loaded model's per-layer KV cache class.
/// The restored checkpoint itself is still validated against live cache
/// shapes before admission; this signature prevents cross-layer/type restores
/// without moving non-Sendable MLX cache objects across actor boundaries.
struct CheckpointLayerShape: Sendable, Equatable {
    let kvHeads: Int
    let headDim: Int

    init?(raw: [Int]?) {
        guard let raw, raw.count == 2, raw[0] > 0, raw[1] > 0 else {
            return nil
        }
        self.kvHeads = raw[0]
        self.headDim = raw[1]
    }

    init(kvHeads: Int, headDim: Int) {
        self.kvHeads = kvHeads
        self.headDim = headDim
    }
}

enum CheckpointLayerSignature: Sendable, Equatable {
    case simple(shape: CheckpointLayerShape?)
    case rotating(window: Int, shape: CheckpointLayerShape?)
    case unsupported

    static func from(_ cache: any KVCache, layerShape: [Int]? = nil) -> CheckpointLayerSignature {
        let shape = CheckpointLayerShape(raw: layerShape)
        if cache is ArraysCache { return .unsupported }
        if cache is ChunkedKVCache { return .unsupported }
        if cache is QuantizedKVCache { return .unsupported }
        if let rotating = cache as? RotatingKVCache, let window = rotating.maxSize, window > 0 {
            return .rotating(window: window, shape: shape)
        }
        if cache is KVCacheSimple, !(cache is RotatingKVCache) {
            return .simple(shape: shape)
        }
        return .unsupported
    }
}

/// Model-architecture fields read from `config.json`, used by
/// `KVEstimation.computeKVBytesPerToken` to size the token budget.
/// All values are post-clamp; see `KVEstimation.parseModelArchitecture`.
struct ModelArchitecture: Sendable {
    let numLayers: Int?
    let kvHeads: Int?
    let headDim: Int?
    let numKvSharedLayers: Int
    let globalHeadDim: Int?
    let numGlobalKvHeads: Int?
    let slidingWindowPattern: Int?
    let layerTypes: [String]?
    let maxContextLength: Int?

    static let empty = ModelArchitecture(
        numLayers: nil,
        kvHeads: nil,
        headDim: nil,
        numKvSharedLayers: 0,
        globalHeadDim: nil,
        numGlobalKvHeads: nil,
        slidingWindowPattern: nil,
        layerTypes: nil,
        maxContextLength: nil
    )
}

/// Type-erased wrapper around the loaded model's tokenizer.
///
/// Wraps the tokenizer in a class so the actor can hold an `Optional`
/// reference without copying the underlying tokenizer state every load.
public final class TokenizerHandle: @unchecked Sendable {
    public let inner: any MLXLMCommon.Tokenizer
    public init(_ inner: any MLXLMCommon.Tokenizer) { self.inner = inner }
}

// MARK: - Error helpers

extension BatchScheduler {
    /// Translate a planner rejection into the canonical
    /// `token_budget_exhausted: <reason>` string.
    ///
    /// `StandaloneServer.schedulerErrorStatus(for:)` and downstream
    /// coordinator code both string-match on the
    /// `token_budget_exhausted:` prefix. Keep the wording stable; any
    /// change here needs paired updates downstream.
    static func errorMessage(for reason: BatchRejectionReason) -> String {
        switch reason {
        case .requestExceedsActiveTokenBudget:
            return "token_budget_exhausted: request exceeds active token budget"
        case .requestExceedsBatchTokenBudget:
            return "token_budget_exhausted: request exceeds batch token budget"
        case .queueFull:
            return "token_budget_exhausted: request queue full"
        case .duplicateRequestID:
            return "token_budget_exhausted: duplicate request ID"
        case .invalidTokenCount:
            return "token_budget_exhausted: invalid token count"
        }
    }
}
