// Copyright © 2026 Eigen Labs.

@preconcurrency import AVFoundation
import Foundation
import MLXLMCommon
import MLXVLM
import Testing

@testable import ProviderCore

/// Every refusal path classifies a video whose reader failed on both passes the
/// same way: a transient decoder fault is a retryable 503 (`capacity`) with
/// error reason `media_memory_unavailable`, any other reader failure is the
/// media's 400 (`invalid_media`).
struct VideoReaderFailureMappingTests {
    private let transient = VideoReaderFailure(
        status: AVAssetReader.Status.failed.rawValue,
        error: NSError(domain: AVFoundationErrorDomain, code: AVError.Code.decoderTemporarilyUnavailable.rawValue))
    private let media = VideoReaderFailure(
        status: AVAssetReader.Status.failed.rawValue,
        error: NSError(domain: AVFoundationErrorDomain, code: AVError.Code.decodeFailed.rawValue))

    private func wire(_ error: Error) -> (InferenceFailureCode, UInt16) {
        let failure = ProviderLoop.sanitizedInferenceFailure(from: error, phase: .streamStart)
        return (failure.code, failure.statusCode)
    }

    /// The media-decode refusal: a 503 the coordinator re-routes without
    /// clamping the provider's text/KV budget or adding a capacity strike.
    private func isMediaDecodeRefusal(_ error: Error) -> Bool {
        let failure = ProviderLoop.sanitizedInferenceFailure(from: error, phase: .streamStart)
        return error as? MultiModelBatchSchedulerEngineError == .mediaMemoryUnavailable
            && failure.code == .capacity && failure.statusCode == 503
            && failure.errorReason == .mediaMemoryUnavailable && failure.terminalCause == nil
    }

    @Test func glmKeepsItsRefusalTextAndLetsTransientFaultsThrough() throws {
        let refusal = EngineV2VisionPrefill.glm5NextInputError(.videoReader(media))
        guard case .unsupportedMedia(let detail)? = refusal as? EngineV2VisionPrefillError else {
            Issue.record("a media reader failure is not a client fault: \(refusal)")
            return
        }
        #expect(detail == "GLM media input: video decoding failed")
        let clientFault = try #require(EngineV2VisionPrefill.clientFault(for: refusal))
        #expect(wire(clientFault) == (.invalidMedia, 400))
        let passedOn = EngineV2VisionPrefill.glm5NextInputError(.videoReader(transient))
        #expect(passedOn as? VideoReaderFailure == transient)
        #expect(EngineV2VisionPrefill.clientFault(for: passedOn) == nil)
    }

    /// Qwen4, and GLM's transient case, reach the shared media funnel as the
    /// failure itself. A transient fault becomes the media-decode refusal; its
    /// telemetry carries the reader's codes. Any other construction failure
    /// keeps the construction refusal, error reason `capacity_busy`.
    @Test func sharedMediaFunnel() throws {
        let clientFault = try #require(EngineV2VisionPrefill.clientFault(for: media))
        #expect(clientFault == .multimodalRejected("multimodal_rejected: the video could not be decoded"))
        #expect(wire(clientFault) == (.invalidMedia, 400))
        #expect(EngineV2VisionPrefill.clientFault(for: transient) == nil)
        #expect(isMediaDecodeRefusal(EngineV2VisionPrefill.constructionRefusal(for: transient, mediaKind: .video)))
        let event = EngineV2VisionPrefill.refusalTelemetryEvent(modelId: "m", mediaKind: .video, error: transient)
        #expect(event.fields?["error"]?.value as? String == transient.description)
        #expect(EngineV2VisionPrefill.refusalDetail(for: transient) == transient.description)

        struct Unrelated: Error {}
        let construction = EngineV2VisionPrefill.constructionRefusal(for: Unrelated(), mediaKind: .image)
        guard case .requestRejected(let message) = construction else {
            Issue.record("a construction failure is not the construction refusal: \(construction)")
            return
        }
        #expect(message.hasPrefix("engine_v2 media prefill construction failed (media=image): "))
        let failure = ProviderLoop.sanitizedInferenceFailure(from: construction, phase: .streamStart)
        #expect(failure.code == .capacity && failure.statusCode == 503 && failure.errorReason == .capacityBusy)
    }

    @Test func mimoAndSuperFunnels() {
        let mimo = MiMoV26EncodedMediaIngress.outwardFailure(media)
        #expect(mimo as? MultiModelBatchSchedulerEngineError
            == .multimodalRejected("native media input is unsupported or exceeds its bound"))
        #expect(wire(mimo) == (.invalidMedia, 400))
        #expect(isMediaDecodeRefusal(MiMoV26EncodedMediaIngress.outwardFailure(transient)))

        let superVideo = SuperHTTPErrors.map(media, media: true)
        #expect(superVideo as? MultiModelBatchSchedulerEngineError
            == .multimodalRejected("the inline video could not be read"))
        #expect(wire(superVideo) == (.invalidMedia, 400))
        #expect(isMediaDecodeRefusal(SuperHTTPErrors.map(transient, media: true)))
    }

    /// A MiMo audio pass that failed twice keeps the audiovisual decoder's refusal
    /// text; its transient fault is the media-decode refusal, and the report and the shared funnel
    /// name the audio medium.
    @Test func audioReaderFailures() {
        func audio(_ code: AVError.Code) -> VideoReaderFailure {
            VideoReaderFailure(status: AVAssetReader.Status.failed.rawValue,
                               error: NSError(domain: AVFoundationErrorDomain, code: code.rawValue), medium: .audio)
        }
        let audioMedia = audio(.decodeFailed)
        let audioTransient = audio(.decoderTemporarilyUnavailable)

        let mimo = MiMoV26EncodedMediaIngress.outwardFailure(audioMedia)
        #expect(mimo as? MultiModelBatchSchedulerEngineError
            == .multimodalRejected("video audio requires contiguous mono24k LPCM16/Float32 without edits"))
        #expect(wire(mimo) == (.invalidMedia, 400))
        #expect(isMediaDecodeRefusal(MiMoV26EncodedMediaIngress.outwardFailure(audioTransient)))

        #expect(EngineV2VisionPrefill.clientFault(for: audioMedia)
            == .multimodalRejected("multimodal_rejected: the audio could not be decoded"))
        #expect(EngineV2VisionPrefill.clientFault(for: audioTransient) == nil)

        let event = VideoReaderFailureReport.event(audioTransient, retrying: false)
        #expect(event.message == "audio reader pass failed again; the audio is refused")
        #expect(event.fields?["operation"]?.value as? String == "audio_reader_failed")
        #expect(event.fields?["reader_error"]?.value as? String
            == "audio reader status 3: AVFoundationErrorDomain -11839")
        #expect(VideoReaderFailureReport.event(audioMedia, retrying: true).message
            == "audio reader pass failed; decoding again with a new reader")
    }

    @Test func reportCarriesTheReaderStatusAndCodesOnly() {
        let event = VideoReaderFailureReport.event(transient, retrying: true)
        #expect(event.severity == .warn && event.kind == .engineHealth)
        let fields = event.fields ?? [:]
        #expect(fields["operation"]?.value as? String == "video_reader_failed")
        #expect(fields["retrying"]?.value as? Bool == true)
        #expect(fields["transient"]?.value as? Bool == true)
        #expect(fields["reader_status"]?.value as? Int == AVAssetReader.Status.failed.rawValue)
        #expect(fields["reader_error"]?.value as? String == "video reader status 3: AVFoundationErrorDomain -11839")
        #expect(VideoReaderFailureReport.event(media, retrying: false).fields?["transient"]?.value as? Bool == false)
        #expect(event.message == "video reader pass failed; decoding again with a new reader")
    }
}
