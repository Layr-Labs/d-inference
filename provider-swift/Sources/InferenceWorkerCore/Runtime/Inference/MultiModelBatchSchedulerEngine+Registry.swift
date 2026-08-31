// Copyright © 2026 Eigen Labs.
//
// Registry value types consumed by ``MultiModelBatchSchedulerEngine``.
//
// These live in a dedicated file so the main engine file only carries
// the `MLXServerEngine` conformance methods + the closure-based
// constructors. The types here are pure data + the
// ``OneShotRelease`` actor; they have no behaviour beyond holding
// references.
//
// v0.7.5 ONE-ENGINE shape: `engineV2Bridge` is the serving engine for
// EVERY production entry — ProviderLoop slots AND the standalone
// `darkbloom start --local` server's slots. A request that reaches an
// entry with NO bridge is a hard internal error (fail-loud insurance).
// `visionGate` owns the media path's memory reservations (media-decode
// RAM + generation KV against the shared budget).

import Foundation
import MLXLMCommon

public extension MultiModelBatchSchedulerEngine {

    /// Snapshot entry for a single loaded model. Returned by the
    /// `registryProvider` closure each time the engine needs to route
    /// a request.
    struct ModelRegistryEntry: Sendable {
        /// Tokenizer wrapper for token-utility endpoints
        /// (`/tokenize`, `/detokenize`, `/apply-template`).
        public let tokenizer: TokenizerHandle
        /// The `model_type` from config.json (e.g. `"gpt_oss"`, `"gemma4"`).
        /// Used to auto-select reasoning and tool call parsers.
        public let modelType: String?
        /// The loaded model container. Present for VLM models so multimodal
        /// requests can run the non-batched `prepare`/`generate` vision path.
        public let container: ModelContainer?
        /// Whether this model is a vision-language model (config has a
        /// `vision_config`). When true, requests that carry image/video
        /// content are routed to the media path.
        public let isVLM: Bool
        /// ContinuousBatchingV2 bridge — the serving engine. Non-nil for
        /// EVERY production entry (ProviderLoop and standalone slots).
        public let engineV2Bridge: EngineV2Bridge?
        /// Memory gate for the legacy VLM media path (media-decode RAM +
        /// generation KV against the shared budget). nil ⇒ gating disabled
        /// (standalone / unit tests without a shared ledger).
        public let visionGate: VisionMemoryGate?

        public init(
            tokenizer: TokenizerHandle,
            modelType: String? = nil,
            container: ModelContainer? = nil, isVLM: Bool = false,
            engineV2Bridge: EngineV2Bridge? = nil,
            visionGate: VisionMemoryGate? = nil
        ) {
            self.tokenizer = tokenizer
            self.modelType = modelType
            self.container = container
            self.isVLM = isVLM
            self.engineV2Bridge = engineV2Bridge
            self.visionGate = visionGate
        }
    }

    /// Tokenizer plus the loaded model type used by token utility endpoints.
    /// `/apply-template` needs both: model-family normalization must not depend
    /// on a registry ID containing a recognizable family name.
    struct TokenizerResolution: Sendable {
        public let tokenizer: TokenizerHandle
        public let modelType: String?

        public init(tokenizer: TokenizerHandle, modelType: String?) {
            self.tokenizer = tokenizer
            self.modelType = modelType
        }
    }

    /// Snapshot type returned by `registryProvider`. Keyed by model id
    /// exactly as it appears in `OpenAIChatCompletionRequest.model`.
    typealias Registry = [String: ModelRegistryEntry]

    /// Result of `acquire(modelId:)`. Carries the engine/tokenizer state
    /// for the just-acquired model plus a `releaseToken` actor that must be
    /// fired exactly once when the request is finished (whether by normal
    /// completion, cancellation, or error). Used by the atomic
    /// `ensureLoaded + reserve` paths (`StandaloneServer`,
    /// `ProviderLoop+LocalEndpoint`).
    struct AcquiredModel: Sendable {

        public let tokenizer: TokenizerHandle
        public let releaseToken: OneShotRelease
        /// The `model_type` from config.json.
        public let modelType: String?
        /// The loaded model container (present for VLM models — see
        /// ``ModelRegistryEntry/container``).
        public let container: ModelContainer?
        /// Whether this model is a vision-language model.
        public let isVLM: Bool
        /// ContinuousBatchingV2 bridge — the serving engine (see
        /// ``ModelRegistryEntry/engineV2Bridge``).
        public let engineV2Bridge: EngineV2Bridge?
        /// Memory gate for the legacy VLM media path (see
        /// ``ModelRegistryEntry/visionGate``).
        public let visionGate: VisionMemoryGate?

        public init(
                        tokenizer: TokenizerHandle,
            releaseToken: OneShotRelease,
            modelType: String? = nil,
            container: ModelContainer? = nil,
            isVLM: Bool = false,
            engineV2Bridge: EngineV2Bridge? = nil,
            visionGate: VisionMemoryGate? = nil
        ) {
            self.tokenizer = tokenizer
            self.releaseToken = releaseToken
            self.modelType = modelType
            self.container = container
            self.isVLM = isVLM
            self.engineV2Bridge = engineV2Bridge
            self.visionGate = visionGate
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
