// Error → HTTP status mapping for inference responses. Split out of
// `ProviderLoop.swift` because the switch is a pure mapping function
// that the standalone HTTP server (`CORSResponder`) also depends on,
// and grouping it with the other request-side helpers keeps the
// status-code contract navigable in one place.

import Foundation
import MLXLMServer

extension ProviderLoop {

    /// Convert any thrown error into the closed provider/coordinator contract.
    /// Raw descriptions are used only by the existing in-process classifier;
    /// neither the returned value nor any downstream sink can carry them.
    static func sanitizedInferenceFailure(
        from error: Error,
        phase: InferenceFailurePhase,
        errorReason: InferenceErrorReason? = nil
    ) -> InferenceFailure {
        let statusCode = mapInferenceErrorToStatus(error)
        let terminal = inferenceTerminalMetadata(from: error)
        let reason = errorReason ?? boundedInferenceErrorReason(
            from: error, terminalCause: terminal.cause)
        return InferenceFailure(
            code: inferenceFailureCode(
                from: error,
                statusCode: statusCode,
                phase: phase,
                errorReason: reason),
            statusCode: statusCode,
            errorReason: reason,
            terminalCause: terminal.cause,
            attemptUsage: terminal.usage)
    }

    /// Map rich in-process errors onto the bounded diagnostic vocabulary. The
    /// associated strings are inspected only to recognize engine-authored
    /// markers; no source string is returned, logged, or serialized.
    private static func boundedInferenceErrorReason(
        from error: Error,
        terminalCause: InferenceTerminalCause?
    ) -> InferenceErrorReason? {
        if error is CancellationError { return .cancelled }
        if let typed = classifyTypedInferenceErrorReason(error) { return typed }
        if let cause = terminalCause {
            switch cause {
            case .admissionTimeout:
                return .capacityTimeout
            case .cancelled:
                return .cancelled
            case .prefillStall, .decodeStall, .safetyDeadline,
                .backpressureTimeout, .watchdog, .engineError:
                return nil
            }
        }
        guard let engineError = error as? MultiModelBatchSchedulerEngineError else {
            return nil
        }
        switch engineError {
        case .modelNotLoaded, .noModelLoadedForTokenization:
            return .modelLoad
        case .invalidRole, .invalidToolPayload, .mediaUnsupportedByModel,
            .multimodalRejected:
            return .clientError
        case .toolChoiceViolation:
            return .toolNoncompliance
        case .queueFull:
            return .queueFull
        case .tokenBudgetExhausted(let message):
            return boundedCapacityReason(from: message, fallback: .tokenBudgetExhausted)
        case .requestRejected(let message):
            let lower = message.lowercased()
            if lower.contains("invalid token count") || lower.contains("duplicate request id") {
                return .clientError
            }
            return boundedCapacityReason(from: message, fallback: .capacityBusy)
        case .generationFailed, .platformTerminal:
            return nil
        }
    }

    private static func boundedCapacityReason(
        from engineMessage: String,
        fallback: InferenceErrorReason
    ) -> InferenceErrorReason {
        let message = engineMessage.lowercased()
        if message.contains("exceeds batch token budget") {
            return .requestExceedsBatchTokenBudget
        }
        if message.contains("context length") || message.contains("context window") {
            return .requestExceedsContext
        }
        if message.contains("active token budget")
            || message.contains("shared kv budget")
            || (message.contains("request requires") && message.contains("available"))
        {
            return .requestExceedsNodeBudget
        }
        if message.contains("timed out waiting for capacity") {
            return .capacityTimeout
        }
        if message.contains("queue full") {
            return .queueFull
        }
        if message.contains("capacity exhausted")
            || message.contains("insufficient global kv cache headroom")
        {
            return .capacityBusy
        }
        return fallback
    }

    private static func inferenceFailureCode(
        from error: Error,
        statusCode: UInt16,
        phase: InferenceFailurePhase,
        errorReason: InferenceErrorReason?
    ) -> InferenceFailureCode {
        if error is CancellationError { return .cancelled }
        if errorReason == .cancelled { return .cancelled }
        if errorReason == .modelLoad { return .modelUnavailable }
        if errorReason == .toolNoncompliance {
            return .generationFailure
        }
        if errorReason == .capacityTimeout
            || errorReason == .queueFull
            || errorReason == .tokenBudgetExhausted
            || errorReason == .requestExceedsContext
            || errorReason == .requestExceedsNode
            || errorReason == .requestExceedsNodeBudget
            || errorReason == .requestExceedsBatchTokenBudget
            || errorReason == .capacityBusy
        {
            return .capacity
        }
        if errorReason == .jinjaChannelTags
            || errorReason == .jinjaNullBridge
            || errorReason == .jinjaTemplate
        {
            return .templateRender
        }

        if let mediaError = error as? MediaIngest.MediaError {
            switch mediaError {
            case .mediaTooLarge:
                return .mediaTooLarge
            case .malformedDataURI,
                .base64DecodeFailed,
                .percentDecodeFailed,
                .imageDecodeFailed,
                .invalidURL:
                return .invalidMedia
            }
        }

        if let engineError = error as? MultiModelBatchSchedulerEngineError {
            switch engineError {
            case .modelNotLoaded, .noModelLoadedForTokenization:
                return .modelUnavailable
            case .invalidRole, .invalidToolPayload:
                return .invalidRequest
            case .toolChoiceViolation, .generationFailed:
                return .generationFailure
            case .queueFull, .tokenBudgetExhausted, .requestRejected:
                return .capacity
            case .mediaUnsupportedByModel:
                return .unsupportedMedia
            case .multimodalRejected:
                return .invalidMedia
            case .platformTerminal(let cause, _, _):
                switch cause {
                case .admissionTimeout:
                    return .capacity
                case .cancelled:
                    return .cancelled
                case .safetyDeadline, .backpressureTimeout, .prefillStall,
                    .decodeStall, .watchdog, .engineError:
                    return .generationFailure
                }
            }
        }

        // `.clientError` is also used as the diagnostic reason for typed media
        // failures. Keep its generic fallback after the concrete media switches
        // so it cannot erase their distinct wire codes.
        if errorReason == .clientError {
            return .invalidRequest
        }
        if phase == .modelLoad { return .modelUnavailable }
        switch statusCode {
        case 400, 422:
            return .invalidRequest
        case 404:
            return .modelUnavailable
        case 429, 503:
            return .capacity
        default:
            return phase == .streamStart || phase == .generation
                ? .generationFailure
                : .internalFailure
        }
    }

    /// Map an error thrown by `MLXOpenAIService` /
    /// `MultiModelBatchSchedulerEngine` to an HTTP-style status code
    /// the coordinator can forward to the consumer. Unmapped errors
    /// fall through to 500.
    ///
    /// I2: the catch-all wrapper previously collapsed every error from
    /// the streaming pipeline into HTTP 500. That hid 4xx-class signals
    /// (e.g. an invalid response_format request) behind a generic
    /// server-error response and made debugging harder. Now we switch
    /// on the concrete error type so the coordinator can forward an
    /// accurate status to the consumer.
    ///
    /// P2 #4 / P2 #5 / P2 #6: the typed scheduler-side admission
    /// errors and the legacy-role rejection are mapped here so the
    /// retry/backoff semantics that existed before the MLXLMServer
    /// adoption are preserved (queue full = 429, token budget /
    /// capacity-timeout = 503, invalid role = 400, model not found =
    /// 404).
    static func mapInferenceErrorToStatus(_ error: Error) -> UInt16 {
        // Task cancellation is the CALLER going away (consumer cancel /
        // coordinator disconnect propagated via handleCancellation's
        // task.cancel()), never a provider fault: 499 (client closed
        // request), matching the mid-stream cancel terminal's wire shape.
        // The coordinator-path pre-stream catch special-cases this before
        // mapping (canonical "request cancelled" + the cancellations stat);
        // this entry is defense-in-depth for every other mapper call site
        // (the standalone --local HTTP path) so a cancel can never surface
        // as a 500 provider error anywhere.
        if error is CancellationError {
            return 499
        }
        if let svcErr = error as? MLXOpenAIServiceError {
            switch svcErr {
            case .invalidResponseFormatOutput, .multipleToolCallsNotAllowed:
                return 422
            case .embeddingsNotConfigured:
                return 501
            case .responseNotFound:
                return 404
            }
        }
        if let engErr = error as? MultiModelBatchSchedulerEngineError {
            switch engErr {
            case .modelNotLoaded:
                return 404
            case .noModelLoadedForTokenization:
                return 404
            case .invalidRole:
                return 400
            case .invalidToolPayload:
                return 400
            case .toolChoiceViolation:
                // The MODEL failed the forced tool_choice contract — output-
                // dependent, so a re-sample / another provider can comply.
                // 422 keeps it on the coordinator's normal bounded-failover
                // path (never the terminal client-error stop set) and out of
                // the 5xx provider-fault classes (E5).
                return 422
            case .queueFull:
                return 429
            case .tokenBudgetExhausted:
                return 503
            case .requestRejected:
                return 503
            case .mediaUnsupportedByModel:
                // Client fault: media sent to a non-VLM model. Fails
                // identically on retry, so 400 (not a 5xx/retry signal).
                return 400
            case .multimodalRejected:
                // v2 engine rejected the media submission at submit time
                // (bad spans / embedding mismatch / block over the per-step
                // budget / non-multimodal model or backend), or the routing
                // engine's deterministic no-consumable-media shape (every
                // media part on a non-user role). Deterministic for this
                // request/engine pairing — 400, never a retry signal.
                // (Other provider-side construction failures refuse loudly
                // as `.requestRejected` → 503 so the coordinator reroutes;
                // the pre-release legacy fallback is gone.)
                return 400
            case .generationFailed:
                return 500
            case .platformTerminal(let cause, _, _):
                // Client-facing status only — the coordinator's HEALTH
                // decisions key off `terminal_cause`, not this code. NEVER 429:
                // the incident report forbids relabeling a policy timeout as a
                // rate limit.
                switch cause {
                case .admissionTimeout:
                    // Capacity wait before engine admission — retry once
                    // capacity frees (matches the token-budget 503 posture).
                    return 503
                case .safetyDeadline, .backpressureTimeout:
                    // Time-bound platform terminals → gateway timeout.
                    return 504
                case .prefillStall, .decodeStall, .watchdog:
                    // Engine progress faults → server error.
                    return 500
                case .cancelled:
                    // Client-closed request (defense-in-depth; the provider
                    // tags cancels 499 directly, not via this enum).
                    return 499
                case .engineError:
                    return 500
                }
            }
        }
        // VLM inline-media decode errors are client faults (a malformed,
        // oversized, or non-`data:` payload the caller controls) → 400.
        // These propagate up from `MediaIngest.stream`'s
        // `continuation.finish(throwing:)` through the engine wrapper.
        if let mediaErr = error as? MediaIngest.MediaError {
            switch mediaErr {
            case .malformedDataURI,
                .base64DecodeFailed,
                .percentDecodeFailed,
                .imageDecodeFailed,
                .invalidURL,
                .mediaTooLarge:
                return 400
            }
        }
        return 500
    }

    /// Extract the typed terminal cause and engine-reconciled usage from an
    /// inference error, for the optional `terminal_cause`/`attempt_usage`
    /// fields on the outgoing `inference_error`. Only a CBv2 platform/engine
    /// terminal carries them; every other error returns (nil, nil) so the wire
    /// message stays byte-identical to the legacy shape.
    static func inferenceTerminalMetadata(
        from error: Error
    ) -> (cause: InferenceTerminalCause?, usage: UsageInfo?) {
        if let engErr = error as? MultiModelBatchSchedulerEngineError,
            case .platformTerminal(let cause, _, let usage) = engErr
        {
            return (cause, usage)
        }
        return (nil, nil)
    }

    static func isStreamClosedWithoutTerminal(_ error: Error) -> Bool {
        if let engineError = error as? MultiModelBatchSchedulerEngineError,
           case .generationFailed(let message) = engineError
        {
            return message == "request stream closed by engine teardown"
        }
        return false
    }
}
