// Copyright © 2026 Eigen Labs.
//
// Pure translation between the provider's OpenAI-shaped
// `ChatCompletionRequest` and the frozen v2 engine contract
// (`CBv2Request` / `CBv2SamplingParams`), plus the admission-error →
// canonical capacity-string mapping. Everything here is static and
// side-effect-free so it can be unit-tested field-by-field without an
// engine or tokenizer.

import Foundation
import MLXLMCommon
#if canImport(os)
import os
#endif

enum EngineV2Translation {

    #if canImport(os)
    private static let logger = Logger(
        subsystem: "com.darkbloom.provider", category: "engine_v2")
    #endif

    // MARK: - Request translation

    /// Build the `CBv2Request` for a tokenized prompt.
    ///
    /// * `maxTokens` defaulting matches the legacy path
    ///   (`BatchScheduler.resolvedMaxTokens`: `request.max_tokens ??
    ///   defaultMaxTokens`).
    /// * `stopTokens` is the bridge-resolved EOS set (see
    ///   ``stopTokenIds(eosTokenIds:tokenizerEOSTokenId:extraEOSTokens:convertTokenToId:)``)
    ///   — resolved once at engine construction per the contract, so B=1
    ///   and batched requests stop identically.
    /// * `stopStrings` carries the request's `stop` sequences; the v2
    ///   engine matches them against held-back detokenized text.
    /// * `cacheScope` is an authenticated remote scope or configured local
    ///   scope. It
    ///   maps onto `CBv2Request.cacheSalt` (TB-007/T-041): a non-empty
    ///   scope REPLACES the cache-level salt in the first block hash so
    ///   tenants can never share cached KV; "" maps to nil (cache-level
    ///   salt fallback for direct/local callers. Remote legacy requests set
    ///   `cacheEnabled=false` and never use that fallback.
    ///   LIVE as of v0.7.5: the production engine runs `PrefixCacheV2`
    ///   whenever `PrefixCachePolicy` funds it.
    /// * `multimodal` (v0.7.5) carries the precomputed vision-prefill spans
    ///   + embeddings for image requests (`EngineV2VisionPrefill`); nil for
    ///   text requests keeps the engine's text path byte-identical.
    static func cbv2Request(
        id: CBv2RequestID,
        promptTokens: [Int],
        request: ChatCompletionRequest,
        defaultMaxTokens: Int,
        stopTokenIds: Set<Int>,
        cacheScope: String = "",
        cacheEnabled: Bool = true,
        multimodal: CBv2MultimodalInput? = nil,
        tokenConstraint: (any CBv2TokenConstraint)? = nil
    ) -> CBv2Request {
        CBv2Request(
            id: id,
            promptTokens: promptTokens,
            sampling: samplingParams(from: request),
            maxTokens: request.max_tokens ?? defaultMaxTokens,
            stopTokens: stopTokenIds,
            stopStrings: request.stop?.asArray ?? [],
            priority: 0,
            cacheSalt: cacheScope.isEmpty ? nil : cacheScope,
            prefixCacheEnabled: cacheEnabled,
            multimodal: multimodal,
            tokenConstraint: tokenConstraint
        )
    }

    /// Per-request sampling translation. Defaults deliberately mirror the
    /// legacy engine path (temperature `?? 0.0` — greedy — exactly as
    /// `BatchScheduler.submit`; unset knobs collapse to the contract's
    /// no-op values so the v2 sampler applies no transform the legacy
    /// sampler would not have applied).
    static func samplingParams(from request: ChatCompletionRequest) -> CBv2SamplingParams {
        let (logitBias, droppedBiasKeys) = parseLogitBiasCountingDropped(request.logit_bias)
        if droppedBiasKeys > 0 {
            // Count only — NEVER the keys/values (they are request content).
            // Silent drops make a client's typo'd bias vanish with no signal;
            // this one-line WARN surfaces it without touching the E2E body.
            #if canImport(os)
            Self.logger.warning(
                "engine_v2: dropped \(droppedBiasKeys) invalid logit_bias key(s) (non-numeric or negative)")
            #endif
        }
        return CBv2SamplingParams(
            temperature: request.temperature ?? 0.0,
            topP: request.top_p ?? 1.0,
            topK: request.top_k ?? 0,
            minP: 0,
            repetitionPenalty: request.repetition_penalty ?? 1.0,
            frequencyPenalty: request.frequency_penalty ?? 0,
            presencePenalty: request.presence_penalty ?? 0,
            seed: request.seed,
            logitBias: logitBias,
            topLogprobs: topLogprobs(
                logprobs: request.logprobs, topLogprobs: request.top_logprobs
            )
        )
    }

    /// OpenAI `logit_bias` arrives as a JSON object keyed by token-id
    /// STRINGS (`{"50256": -100}`); the contract wants `[Int: Float]`.
    /// Non-numeric keys are dropped (never guessed) — an invalid key can't
    /// silently bias a random token id.
    static func parseLogitBias(_ raw: [String: Float]?) -> [Int: Float] {
        parseLogitBiasCountingDropped(raw).bias
    }

    /// Same parse as `parseLogitBias`, but also returns how many keys were
    /// dropped (non-numeric or negative) so the caller can surface a signal
    /// for an otherwise-silent drop. Pure — no logging here so it stays
    /// unit-testable field-by-field.
    static func parseLogitBiasCountingDropped(
        _ raw: [String: Float]?
    ) -> (bias: [Int: Float], dropped: Int) {
        guard let raw, !raw.isEmpty else { return ([:], 0) }
        var out: [Int: Float] = [:]
        out.reserveCapacity(raw.count)
        var dropped = 0
        for (key, value) in raw {
            guard let id = Int(key.trimmingCharacters(in: .whitespaces)), id >= 0 else {
                dropped += 1
                continue
            }
            out[id] = value
        }
        return (out, dropped)
    }

    /// OpenAI `logprobs`/`top_logprobs` → contract `topLogprobs`.
    ///
    /// CONTRACT NOTE (see docs/engine-v2/CONTRACT-ISSUES-H-provider.md):
    /// `CBv2SamplingParams.topLogprobs == 0` means "no logprobs at all", so
    /// the OpenAI shape "logprobs=true, top_logprobs omitted/0" (chosen
    /// token's logprob only, no alternatives) has no exact representation.
    /// Closest conforming mapping: request 1 top alternative so the chosen
    /// token's logprob is still captured. `top_logprobs` is clamped to the
    /// OpenAI wire maximum of 20.
    static func topLogprobs(logprobs: Bool?, topLogprobs: Int?) -> Int {
        guard logprobs == true else { return 0 }
        let requested = topLogprobs ?? 0
        return min(20, max(1, requested))
    }

    // MARK: - Logprobs translation (CBv2TokenLogprob → OpenAI entry shape)

    /// Convert engine-emitted logprobs into the OpenAI streaming entry
    /// shape (`choices[].logprobs.content[]`): token text via the caller's
    /// detokenizer, raw UTF-8 `bytes` (the OpenAI escape hatch for BPE
    /// intermediates whose text is not valid standalone UTF-8), and the
    /// `top_logprobs` alternatives. Pure — the decode closure is the only
    /// dependency, so this is unit-testable without an engine.
    static func sseTokenLogprobs(
        _ logprobs: [CBv2TokenLogprob],
        decodeToken: (Int) -> String
    ) -> [SSETokenLogprob] {
        logprobs.map { entry in
            let token = decodeToken(entry.token)
            return SSETokenLogprob(
                token: token,
                logprob: entry.logprob,
                bytes: Array(token.utf8).map(Int.init),
                topLogprobs: entry.topLogprobs.map { alt in
                    let altToken = decodeToken(alt.token)
                    return SSETokenLogprob.Top(
                        token: altToken,
                        logprob: alt.logprob,
                        bytes: Array(altToken.utf8).map(Int.init)
                    )
                }
            )
        }
    }

    // MARK: - Stop resolution (buildStopTokenIds semantics)

    /// Reimplements `MLXLMCommon.buildStopTokenIds` (private upstream) so
    /// the v2 stop set is resolved from the SAME three sources the B=1
    /// generate loop uses: the model configuration's `eosTokenIds`, the
    /// tokenizer's own EOS id, and the configuration's `extraEOSTokens`
    /// (converted via the tokenizer). Resolution happens once at engine
    /// construction — identical for B=1 and batched requests.
    static func stopTokenIds(
        eosTokenIds: Set<Int>,
        tokenizerEOSTokenId: Int?,
        extraEOSTokens: [String],
        convertTokenToId: (String) -> Int?
    ) -> Set<Int> {
        var stopTokenIds = eosTokenIds
        if let tokenizerEOS = tokenizerEOSTokenId {
            stopTokenIds.insert(tokenizerEOS)
        }
        for token in extraEOSTokens {
            if let id = convertTokenToId(token) {
                stopTokenIds.insert(id)
            }
        }
        return stopTokenIds
    }

    // MARK: - Admission-error mapping

    /// Map a thrown `CBv2Engine.submit` error onto the provider's canonical
    /// capacity-error strings. The `token_budget_exhausted:` prefix is the
    /// stable contract that `MultiModelBatchSchedulerEngineError
    /// .fromSchedulerMessage` (and the coordinator) string-match to produce
    /// the retryable 429/503 classification — identical to the legacy
    /// engine's admission rejections.
    /// Canonical marker for submit-time `CBv2MultimodalError` rejections.
    /// `MultiModelBatchSchedulerEngineError.fromSchedulerMessage` maps it to
    /// `.multimodalRejected` → 400: every case is a deterministic property
    /// of the request/engine pairing (bad spans, mismatched embeddings, an
    /// image block over the per-step budget, a non-multimodal model or
    /// backend), never transient capacity — a retry fails identically, so a
    /// retryable 429/503 signal would be a lie. In practice the provider's
    /// own construction (`EngineV2VisionPrefill`) validates spans/embeddings
    /// before submit and production engines always run the contiguous
    /// backend, so these rejections indicate a provider-side gating bug and
    /// double as its loud signal.
    static let multimodalRejectedPrefix = "multimodal_rejected"

    static func admissionErrorMessage(for error: Error) -> String {
        if let mmError = error as? CBv2MultimodalError {
            switch mmError {
            case .unsupportedModel(let detail):
                return "\(multimodalRejectedPrefix): model cannot serve vision "
                    + "through engine_v2 (\(detail))"
            case .unsupportedBackend(let detail):
                return "\(multimodalRejectedPrefix): backend cannot serve vision "
                    + "through engine_v2 (\(detail))"
            case .invalidSpans(let detail):
                return "\(multimodalRejectedPrefix): invalid image spans (\(detail))"
            case .spanTooLong(let blockTokens, let maxBatchedTokensPerStep):
                return "\(multimodalRejectedPrefix): image block of \(blockTokens) "
                    + "tokens exceeds the engine's per-step budget "
                    + "(\(maxBatchedTokensPerStep))"
            case .embeddingMismatch(let detail):
                return "\(multimodalRejectedPrefix): image embeddings mismatch (\(detail))"
            }
        }
        if let kvError = error as? CBv2KVError {
            switch kvError {
            case .capacityExhausted(let needed, let available):
                // Two engine rejection families share this case (round-3
                // PR#499 P2 — `EngineV2.submit`):
                //
                //   * KV capacity ("could never fit"): thrown with the REAL
                //     byte figures — `needed` = `AdmissionV2.estimatedBytes`
                //     for prompt+max (a multiple of the per-token KV cost,
                //     never 1) and `available` = `admissibleBytesCapacity`
                //     (> 0 for any constructible engine, which requires
                //     `kvBytesCapacity > 0`).
                //   * Waiting-queue full / draining-for-shutdown guards:
                //     thrown with the sentinel shape `(needed: 1,
                //     available: 0)` — no byte estimate exists because the
                //     rejection is about SLOTS, not bytes.
                //
                // The legacy path distinguishes these — queue-full carries
                // the canonical "request queue full" marker that
                // `MultiModelBatchSchedulerEngineError.fromSchedulerMessage`
                // maps to `.queueFull` (429 + Retry-After), while budget
                // exhaustion maps to `.tokenBudgetExhausted` (503) — so map
                // the sentinel to the SAME legacy queue-full string
                // (`BatchSchedulerTypes.RejectionReason.queueFull`). The
                // shutdown-drain guard riding the same sentinel also lands
                // on queue-full, exactly like the legacy handler's
                // `.queueFull("provider shutting down")`. No new
                // classification strings.
                if needed == 1 && available <= 0 {
                    return "token_budget_exhausted: request queue full"
                }
                return "token_budget_exhausted: request requires \(needed) tokens "
                    + "but only \(available) available"
            case .backendIneligible(let reason):
                // Deterministic (this model/backend pair can never serve) —
                // NOT retryable capacity. Keep it off the capacity prefix so
                // it maps to a non-retryable failure.
                return "engine_v2 backend ineligible: \(reason)"
            }
        }
        // Unknown throw: do NOT claim capacity exhaustion (which would be
        // retried) — surface as a generic generation failure (500).
        return "engine_v2 submit failed: \(error.localizedDescription)"
    }
}
