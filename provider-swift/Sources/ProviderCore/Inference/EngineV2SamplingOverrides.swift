// Copyright © 2026 Eigen Labs.
//
// Sampling fields that ride the E2E-sealed request body but are NOT modeled
// by the upstream `OpenAIChatCompletionRequest` shape (see
// `libs/mlx-swift-lm/Libraries/MLXLMServer/Protocol/OpenAIProtocol.swift`).
//
// The coordinator inference handler strict-decodes inbound requests into the
// upstream shape, so anything absent from it must be decoded straight from
// the raw body and threaded in out-of-band — the same pattern
// `reasoning_effort`, the prefix-cache scope, and `logprobs`/`top_logprobs`
// already use (`ProviderLoop+InboundDecode`). Without this, OpenAI
// `logit_bias` and `seed` were silently dropped on the coordinator serving
// path: `MultiModelBatchSchedulerEngine.translate` rebuilt the internal
// `ChatCompletionRequest` from the upstream shape only, so
// `EngineV2Translation.parseLogitBias(request.logit_bias)` always saw nil.
//
// Consumed by the v2 engine path only (`EngineV2Translation.samplingParams`);
// the legacy engine never honored either knob, and its submit call is left
// byte-identical (flag-off invariant).

import Foundation

/// OpenAI sampling knobs decoded out-of-band from the sealed request body
/// and overlaid onto the v2 engine translation. Present ⇒ the request
/// carried at least one of the fields.
public struct EngineV2SamplingOverrides: Sendable, Equatable {
    /// OpenAI `logit_bias`: token-id (STRING keys on the wire) → additive
    /// bias. Parsed to `[Int: Float]` by `EngineV2Translation.parseLogitBias`
    /// (invalid keys dropped, never guessed).
    public let logitBias: [String: Float]?
    /// OpenAI `seed` for best-effort reproducible sampling
    /// (`CBv2SamplingParams.seed`; RNG key is (seed, requestID, stepIndex)).
    public let seed: UInt64?

    public init(logitBias: [String: Float]?, seed: UInt64?) {
        self.logitBias = logitBias
        self.seed = seed
    }
}
