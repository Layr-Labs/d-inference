// Copyright © 2026 Eigen Labs.
//
// What a failed media preparation tells the caller.
//
// There are three answers. The loaded artifact can never serve the request, on
// any provider: the request's own fault, a 400. This provider could not build
// the submission: a retryable 503 the coordinator reroutes. This Mac's decoder
// failed just now: a retryable 503 that costs the provider no capacity strike.
//
// The answer is chosen once, here. Every `EngineV2VisionPrefillError` case
// names its answer in a `switch` without a `default:`, a tower limit carries
// who owns it (`MediaLimitOwner`), and the three routes that prepare media
// share `MediaFailure.outward`. HTTP status, failure code and error reason are
// the coordinator's contract, so an answer here changes only with platform
// review.

import Foundation
import MLXLMCommon
import MLXVLM

/// Who owns a limit the vision tower refused a request for. The owner, not the
/// refusal's text, says whether another provider could serve the same request.
enum MediaLimitOwner: Sendable, Equatable {
    /// The model artifact and the code that serves it. Every provider refuses
    /// the request the same way, so the request is at fault.
    case artifact
    /// A ceiling this Mac's operator set below the device's
    /// (`DARKBLOOM_VISION_MAX_TOWER_PATCHES`). A provider without it can serve
    /// the request.
    case operatorLimit
    /// This Mac's GPU: the largest single buffer Metal allocates on it. A
    /// larger Mac can serve the request.
    case device
}

/// The one mapping from a media preparation's throw to what the caller is told.
enum MediaFailure {

    /// The answer a failure gets. It is the same on every route.
    enum Disposition: Equatable {
        /// The request's own fault: every provider serving the artifact, one
        /// Mac or a pair, fails it the same way, so a retriable refusal would
        /// only repeat it elsewhere. HTTP 400 with this message, which is
        /// always our own fixed text: processor text carries media dimensions.
        case clientFault(message: String)
        /// This Mac's media decode failed just now, which says nothing about
        /// its text or KV capacity. A retryable 503 with the reason
        /// `media_memory_unavailable`.
        case decodeUnavailable
        /// This provider could not build the submission. A retryable 503 with
        /// the reason `capacity_busy`, which the coordinator reroutes.
        case constructionRefusal
    }

    /// The routes that prepare media and answer its failures through `outward`.
    enum Route: CaseIterable {
        /// A v2-bridged slot on one Mac.
        case singleMac
        /// GLM on a tensor-parallel pair.
        case glmPair
        /// Qwen on a tensor-parallel pair.
        case qwenPair

        /// Whether a refusal the coordinator reroutes is also published as an
        /// ERROR `engine_v2_vision_refusal` event. The Qwen pair has never
        /// published one. Publishing it changes what telemetry reports, so it
        /// is a reviewed change of its own, made here.
        var publishesRefusalTelemetry: Bool {
            switch self {
            case .singleMac, .glmPair: return true
            case .qwenPair: return false
            }
        }
    }

    /// The answer for a throw that is not already typed for the provider loop
    /// (`outward` lets those through first).
    ///
    /// A video or audio reader that failed on both passes is the media's fault
    /// unless its code is a transient decoder fault. The processor refusing the
    /// media itself is the request's fault: a geometry its resize cannot use
    /// (such as Qwen's side below `patch_size × merge_size` or an aspect ratio
    /// over 200:1), a video without a decodable track, a media count it does
    /// not take. An error no arm knows is this provider's construction failure.
    static func disposition(of error: Error) -> Disposition {
        if let readerFailure = error as? VideoReaderFailure {
            return readerFailure.isTransient
                ? .decodeUnavailable
                : .clientFault(
                    message: "multimodal_rejected: the \(readerFailure.medium.rawValue) could not be decoded")
        }
        if let visionError = error as? EngineV2VisionPrefillError { return visionError.disposition }
        guard let processorError = error as? VLMError else { return .constructionRefusal }
        switch processorError {
        case .imageProcessingFailure:
            return .clientFault(
                message: "multimodal_rejected: the model's processor cannot resize this media "
                    + "(a side below its minimum, an aspect ratio above its limit or no frame)")
        case .noVideoTrackFound, .videoNotDecodable:
            return .clientFault(message: "multimodal_rejected: the video has no decodable video track")
        case .imageRequired, .singleImageAllowed, .singleVideoAllowed, .singleMediaTypeAllowed:
            return .clientFault(
                message: "multimodal_rejected: the model's processor does not take this number or mix of media")
        case .maskRequired, .processing:
            // Processor configuration or internal agreement, not the media.
            return .constructionRefusal
        }
    }

    /// The error that leaves `route` for a throw of its media preparation.
    ///
    /// Errors already typed for the provider loop leave unchanged: the early
    /// first-content refusal, the caller going away (499), the ingest's own
    /// input faults (their 4xx) and the engine's errors (the bridge's
    /// `tokenBudgetExhausted` admission refusal is capacity, not a construction
    /// fault). Every other throw gets its `disposition`; a refusal the
    /// coordinator reroutes is published first, on a route that publishes them.
    static func outward(
        _ error: Error, route: Route, modelId: String, mediaKind: EngineV2MediaKind,
        emitTelemetry: (TelemetryEvent) -> Void
    ) -> Error {
        if let failure = error as? PreContentDeadlineFailure { return failure }
        if error is CancellationError { return CancellationError() }
        if let mediaError = error as? MediaIngest.MediaError { return mediaError }
        if let engineError = error as? MultiModelBatchSchedulerEngineError { return engineError }
        if let clientFault = EngineV2VisionPrefill.clientFault(for: error) { return clientFault }
        if route.publishesRefusalTelemetry {
            emitTelemetry(
                EngineV2VisionPrefill.refusalTelemetryEvent(
                    modelId: modelId, mediaKind: mediaKind, error: error))
        }
        return EngineV2VisionPrefill.constructionRefusal(for: error, mediaKind: mediaKind)
    }
}

extension EngineV2VisionPrefillError {
    /// The answer for each case. There is no `default:`, so a new case does not
    /// compile until its answer is chosen here.
    var disposition: MediaFailure.Disposition {
        switch self {
        case .noProcessedMedia:
            return .clientFault(
                message: "multimodal_rejected: media parts must be attached to user "
                    + "messages; none of this request's media was consumable")
        case .unsupportedMedia(let detail):
            return .clientFault(message: "multimodal_rejected: \(detail)")
        case .towerBudgetExceeded(let owner, _):
            switch owner {
            case .artifact:
                // Every provider refuses this request the same way, which is a
                // client fault. It has always been answered as the retried
                // refusal, and a 400 changes a status the coordinator sees.
                return .constructionRefusal
            case .operatorLimit, .device:
                // Another provider can serve the request.
                return .constructionRefusal
            }
        case .videoPlaceholderUnavailable:
            // The artifact's own config disables video, the same on every
            // provider. Answered as the retried refusal for the same reason.
            return .constructionRefusal
        case .unsupportedVLM, .emptyVisionFeatures, .misalignedDeepstack,
            .conflictingPlaceholderIds, .placeholderRunMissing, .placeholderRunTooShort,
            .unexpectedTrailingPlaceholders, .invalidFeatureLength, .invalidVisionGrid,
            .visionPixelRunMismatch, .towerAllocationRefused, .towerFault:
            return .constructionRefusal
        }
    }
}
