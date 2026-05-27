// Copyright © 2026 Eigen Labs.
//
// Registry value types consumed by ``MultiModelBatchSchedulerEngine``.
//
// These live in a dedicated file so the main engine file only carries
// the `MLXServerEngine` conformance methods + the closure-based
// constructors. The types here are pure data + the
// ``OneShotRelease`` actor; they have no behaviour beyond holding
// references.

import Foundation

public extension MultiModelBatchSchedulerEngine {

    /// Snapshot entry for a single loaded model. Returned by the
    /// `registryProvider` closure each time the engine needs to route
    /// a request to a scheduler.
    struct ModelRegistryEntry: Sendable {
        /// The scheduler that owns this model's `BatchedEngine`.
        public let scheduler: BatchScheduler
        /// Tokenizer wrapper for token-utility endpoints
        /// (`/tokenize`, `/detokenize`, `/apply-template`).
        public let tokenizer: TokenizerHandle
        /// The `model_type` from config.json (e.g. `"gpt_oss"`, `"gemma2"`,
        /// `"qwen3"`). Used to auto-select reasoning and tool call parsers.
        public let modelType: String?

        public init(scheduler: BatchScheduler, tokenizer: TokenizerHandle, modelType: String? = nil) {
            self.scheduler = scheduler
            self.tokenizer = tokenizer
            self.modelType = modelType
        }
    }

    /// Snapshot type returned by `registryProvider`. Keyed by model id
    /// exactly as it appears in `OpenAIChatCompletionRequest.model`.
    typealias Registry = [String: ModelRegistryEntry]

    /// Result of `acquire(modelId:)`. Carries the scheduler/tokenizer
    /// pair for the just-acquired model plus a `releaseToken` actor
    /// that must be fired exactly once when the request is finished
    /// (whether by normal completion, cancellation, or error). Used by
    /// the atomic `ensureLoaded + reserve` path that `StandaloneServer`
    /// implements as a single actor-isolated method (I1 fix).
    struct AcquiredModel: Sendable {
        public let scheduler: BatchScheduler
        public let tokenizer: TokenizerHandle
        public let releaseToken: OneShotRelease
        /// The `model_type` from config.json.
        public let modelType: String?

        public init(
            scheduler: BatchScheduler,
            tokenizer: TokenizerHandle,
            releaseToken: OneShotRelease,
            modelType: String? = nil
        ) {
            self.scheduler = scheduler
            self.tokenizer = tokenizer
            self.releaseToken = releaseToken
            self.modelType = modelType
        }
    }
}

/// Ensures the release closure runs exactly once even though the
/// streaming task body and the `onTermination` handler can both fire
/// on a cancellation race.
public actor OneShotRelease {
    private let release: @Sendable (String) async -> Void
    private let modelId: String
    private var fired = false

    public init(release: @escaping @Sendable (String) async -> Void, modelId: String) {
        self.release = release
        self.modelId = modelId
    }

    public func fire() async {
        guard !fired else { return }
        fired = true
        await release(modelId)
    }
}
