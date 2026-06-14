// Error → HTTP status mapping for inference responses. Split out of
// `ProviderLoop.swift` because the switch is a pure mapping function
// that the standalone HTTP server (`CORSResponder`) also depends on,
// and grouping it with the other request-side helpers keeps the
// status-code contract navigable in one place.

import Foundation
import MLXLMServer

extension ProviderLoop {

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
        if let svcErr = error as? MLXOpenAIServiceError {
            switch svcErr {
            case .invalidResponseFormatOutput:
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
            case .generationFailed:
                return 500
            }
        }
        // VLM inline-media decode errors. All but the temp-file write are
        // client faults (a malformed/oversized/non-`data:` payload the caller
        // controls) → 400. `videoWriteFailed` is a provider-side IO failure
        // → 500. These propagate up from `VLMRequestInference.stream`'s
        // `continuation.finish(throwing:)` through the engine wrapper.
        if let mediaErr = error as? VLMRequestInference.MediaError {
            switch mediaErr {
            case .malformedDataURI,
                .base64DecodeFailed,
                .percentDecodeFailed,
                .imageDecodeFailed,
                .invalidURL,
                .mediaTooLarge:
                return 400
            case .videoWriteFailed:
                return 500
            }
        }
        return 500
    }
}
