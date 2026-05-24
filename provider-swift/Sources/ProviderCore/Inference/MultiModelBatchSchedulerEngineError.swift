// Copyright © 2026 Eigen Labs.
//
// Typed errors emitted by ``MultiModelBatchSchedulerEngine`` and the
// scheduler-message parser that promotes BatchScheduler `.error(...)`
// payloads into those typed cases.
//
// Split out of `MultiModelBatchSchedulerEngine.swift` so the error
// surface and its message-prefix dictionary stay self-contained and
// independently navigable; the engine itself only depends on the
// public cases here.

import Foundation

/// Errors surfaced by ``MultiModelBatchSchedulerEngine`` that map to
/// HTTP-status-bearing OpenAI error responses upstream.
///
/// The scheduler emits `.error(String)` events with structured message
/// prefixes (see ``BatchScheduler``); the engine translates those into
/// typed cases here so ``ProviderLoop/mapInferenceErrorToStatus(_:)``
/// can return retry/backoff-bearing status codes (429/503) instead of
/// collapsing every admission failure into a generic 500.
public enum MultiModelBatchSchedulerEngineError: Error, LocalizedError, Equatable {
    /// The request named a model that is not currently resident.
    case modelNotLoaded(String)
    /// The scheduler emitted an `.error` event during generation that
    /// did not match any of the structured admission/capacity prefixes
    /// below. Treated as a generic 500 by the status mapper.
    case generationFailed(String)
    /// `tokenize`/`detokenize`/`applyTemplate` were called but no model
    /// is loaded, so we have no tokenizer to hand off to upstream.
    case noModelLoadedForTokenization
    /// Inbound request named a chat role we do not recognise (i.e. it
    /// is not one of `system`/`user`/`assistant`/`tool`). Surfaced as
    /// 400 so callers can fix the role rather than the previous silent
    /// coercion to `user` that changed prompt semantics.
    case invalidRole(String)
    /// Admission rejection caused by the batch token budget / global
    /// KV-cache headroom / pending-queue timeout. Surfaces as 503 so
    /// clients back off and retry once capacity frees up.
    case tokenBudgetExhausted(String)
    /// Pending request queue is full. Surfaces as 429 so clients can
    /// honour a retry-after.
    case queueFull(String)
    /// Catch-all for other planner-rejected admission failures (for
    /// example a future "request_rejected: ..." path). Surfaces as
    /// 503 — the request was not run and the client may safely retry.
    case requestRejected(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded(let id):
            return "Model '\(id)' is not loaded on this provider"
        case .generationFailed(let message):
            return message
        case .noModelLoadedForTokenization:
            return "No model is loaded; cannot tokenize or apply template"
        case .invalidRole(let role):
            return "Unsupported chat message role: '\(role)'"
        case .tokenBudgetExhausted(let message):
            return message
        case .queueFull(let message):
            return message
        case .requestRejected(let message):
            return message
        }
    }

    /// Map a `BatchScheduler` `.error(message)` payload into a typed
    /// engine error. Recognises the structured prefixes that
    /// ``BatchScheduler`` and its planner emit; anything else stays
    /// as ``generationFailed`` so the operator-facing message is
    /// preserved verbatim.
    ///
    /// Order matters here: "queue full" must be checked before the
    /// generic `token_budget_exhausted` prefix because the planner's
    /// queue-full rejection is reported as
    /// `token_budget_exhausted: request queue full`.
    static func fromSchedulerMessage(_ message: String) -> MultiModelBatchSchedulerEngineError {
        let lowercased = message.lowercased()
        // Planner validation failures share the `token_budget_exhausted:`
        // prefix but are request-shape errors, NOT transient capacity
        // exhaustion. Map them to 400 (`.requestRejected`) so clients
        // don't get a misleading 503 + retry signal for a request that
        // will fail identically on retry.
        if lowercased.contains("invalid token count")
            || lowercased.contains("duplicate request id")
            || lowercased.contains("exceeds batch token budget")
        {
            return .requestRejected(message)
        }
        if lowercased.contains("queue full") {
            return .queueFull(message)
        }
        if lowercased.contains("token_budget_exhausted")
            || lowercased.contains("timed out waiting for capacity")
            || lowercased.contains("insufficient global kv cache headroom")
        {
            return .tokenBudgetExhausted(message)
        }
        return .generationFailed(message)
    }
}
