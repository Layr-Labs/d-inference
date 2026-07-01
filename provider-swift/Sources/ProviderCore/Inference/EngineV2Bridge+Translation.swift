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

enum EngineV2Translation {

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
    static func cbv2Request(
        id: CBv2RequestID,
        promptTokens: [Int],
        request: ChatCompletionRequest,
        defaultMaxTokens: Int,
        stopTokenIds: Set<Int>
    ) -> CBv2Request {
        CBv2Request(
            id: id,
            promptTokens: promptTokens,
            sampling: samplingParams(from: request),
            maxTokens: request.max_tokens ?? defaultMaxTokens,
            stopTokens: stopTokenIds,
            stopStrings: request.stop?.asArray ?? [],
            priority: 0
        )
    }

    /// Per-request sampling translation. Defaults deliberately mirror the
    /// legacy engine path (temperature `?? 0.0` — greedy — exactly as
    /// `BatchScheduler.submit`; unset knobs collapse to the contract's
    /// no-op values so the v2 sampler applies no transform the legacy
    /// sampler would not have applied).
    static func samplingParams(from request: ChatCompletionRequest) -> CBv2SamplingParams {
        CBv2SamplingParams(
            temperature: request.temperature ?? 0.0,
            topP: request.top_p ?? 1.0,
            topK: request.top_k ?? 0,
            minP: 0,
            repetitionPenalty: request.repetition_penalty ?? 1.0,
            frequencyPenalty: request.frequency_penalty ?? 0,
            presencePenalty: request.presence_penalty ?? 0,
            seed: request.seed,
            logitBias: parseLogitBias(request.logit_bias),
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
        guard let raw, !raw.isEmpty else { return [:] }
        var out: [Int: Float] = [:]
        out.reserveCapacity(raw.count)
        for (key, value) in raw {
            guard let id = Int(key.trimmingCharacters(in: .whitespaces)), id >= 0 else {
                continue
            }
            out[id] = value
        }
        return out
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
    static func admissionErrorMessage(for error: Error) -> String {
        if let kvError = error as? CBv2KVError {
            switch kvError {
            case .capacityExhausted(let needed, let available):
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
