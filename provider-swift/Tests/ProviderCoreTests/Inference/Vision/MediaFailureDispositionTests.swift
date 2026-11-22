// Copyright © 2026 Eigen Labs.
//
// What a failed media preparation tells the coordinator: HTTP status, failure
// code and error reason, pinned for every error a preparation can throw, on
// each of the three routes that prepare media (one Mac, the GLM pair, the Qwen
// pair). The rows come from exhaustive switches over the error enums, so a new
// case does not compile until it has a row. An answer that is pinned although
// another is intended is listed once, in `KnownDivergence`. No model weights.

@preconcurrency import AVFoundation
import Foundation
import MLXLLM
import MLXLMCommon
import MLXVLM
import Testing

@testable import ProviderCore

// MARK: - The contract

/// What the coordinator is told about one failure.
private struct Answer: Equatable, CustomStringConvertible {
    let status: UInt16
    let code: InferenceFailureCode
    let reason: InferenceErrorReason?

    var description: String { "\(status) \(code.rawValue) \(reason?.rawValue ?? "no reason")" }

    /// The request's own fault.
    static let clientFault = Answer(status: 400, code: .invalidMedia, reason: .clientError)
    /// This provider could not build the submission, so the coordinator reroutes.
    static let constructionRefusal = Answer(status: 503, code: .capacity, reason: .capacityBusy)
    /// This Mac could not decode the media just now: rerouted without a capacity strike.
    static let decodeUnavailable = Answer(
        status: 503, code: .capacity, reason: .mediaMemoryUnavailable)

    init(status: UInt16, code: InferenceFailureCode, reason: InferenceErrorReason?) {
        self.status = status
        self.code = code
        self.reason = reason
    }

    /// The provider loop's answer for an error thrown before the stream starts:
    /// the classifier's reason, then `sanitizedInferenceFailure`.
    init(for error: Error) {
        let failure = ProviderLoop.sanitizedInferenceFailure(
            from: error, phase: .streamStart, errorReason: classifyInferenceErrorReason(error))
        self.init(status: failure.statusCode, code: failure.code, reason: failure.errorReason)
    }
}

/// Answers this suite pins although they are arguably wrong. Each flip changes a
/// status, code or reason the coordinator sees, so it needs platform review and
/// its own change. An entry leaves this list when its answer is corrected; none
/// is added.
private enum KnownDivergence: CaseIterable {
    /// `towerBudgetExceeded` with an artifact-owned limit (GLM's aggregate patch
    /// limit, a GLM frame's byte overflow, an unrepresentable patch grid) is the
    /// same on every provider, yet answered as the retried 503.
    case artifactTowerLimitIsRetried
    /// `videoPlaceholderUnavailable`: the artifact's own config disables video,
    /// yet a video request is answered as the retried 503.
    case disabledVideoIsRetried
    /// A pair's still-image ingress (GLM, MiMo) that is stopping or not ready
    /// rethrows a raw `DistributedEngineError`: the generic 500 there, a 400
    /// where submission translates the same refusal.
    case pairImageRefusalIsUnmapped
    /// The Qwen pair route publishes no refusal telemetry; the other two do.
    case qwenPairPublishesNoRefusalTelemetry
    /// Nemotron Super's `Failure.capacity` is the retried
    /// `media_memory_unavailable` for arithmetic no Mac can satisfy, too.
    case superCapacityCoversDeterministicRefusals
    /// A chat template that does not render while media is prepared fails the
    /// same way on every provider, yet leaves with the refusal's 503: the
    /// refusal's text names the error's type, which the loop's classifier
    /// reads as `jinja_template`. The text path answers it with a 500.
    case templateFailureKeepsTheRefusalStatus
}

/// One error a media preparation can throw, with the answer every route gives it.
private struct Row {
    let error: any Error
    let pinned: Answer
    /// Every provider serving the artifact refuses the request the same way.
    let artifactOwned: Bool
    /// A route that publishes refusal telemetry publishes one event for it.
    let publishesRefusal: Bool
    let divergence: KnownDivergence?

    var name: String { "\(type(of: error)): \(error)" }

    /// The request's own fault on every provider: 400, no refusal event.
    static func clientFault(_ error: any Error) -> Row {
        Row(error: error, pinned: .clientFault, artifactOwned: true, publishesRefusal: false, divergence: nil)
    }

    /// The retried construction refusal and its event.
    static func refused(_ error: any Error) -> Row {
        Row(error: error, pinned: .constructionRefusal, artifactOwned: false, publishesRefusal: true, divergence: nil)
    }

    /// The same on every provider, yet refused as if another could serve it: a
    /// pinned divergence.
    static func refusedThoughArtifactOwned(
        _ error: any Error, _ divergence: KnownDivergence, answer: Answer = .constructionRefusal
    ) -> Row {
        Row(error: error, pinned: answer, artifactOwned: true, publishesRefusal: true, divergence: divergence)
    }

    /// This Mac's decoder failed just now: the retried media refusal and its event.
    static func decodeUnavailable(_ error: any Error) -> Row {
        Row(error: error, pinned: .decodeUnavailable, artifactOwned: false, publishesRefusal: true, divergence: nil)
    }

    /// Already typed for the provider loop: rethrown unchanged, never a refusal event.
    static func passedThrough(_ error: any Error, _ answer: Answer, artifactOwned: Bool = false) -> Row {
        Row(error: error, pinned: answer, artifactOwned: artifactOwned, publishesRefusal: false, divergence: nil)
    }
}

/// An error no media classification knows.
struct MediaFailureUnclassifiedError: Error {}

/// Stands in for `Jinja.TemplateException`: the loop's classifier knows a
/// template failure by this word in the error's type name.
struct MediaFailureTemplateException: Error {}

/// The answer of a template failure that media preparation refused.
private let refusedTemplateFailure = Answer(status: 503, code: .templateRender, reason: .jinjaTemplate)

/// Collects the refusal events a route publishes.
final class MediaRefusalEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TelemetryEvent] = []
    var events: [TelemetryEvent] { lock.withLock { recorded } }
    var record: @Sendable (TelemetryEvent) -> Void {
        { [self] event in lock.withLock { recorded.append(event) } }
    }
}

private enum Table {
    static let rows: [Row] =
        prefillRows() + readerRows() + processorRows() + mediaErrorRows() + passedThroughRows
        + unclassifiedRows

    /// One row per case of `EngineV2VisionPrefillError` and per owner of a tower
    /// limit. Each arm pins its case and names the next sample; the switch has
    /// no `default:`, so a new case or owner does not compile until it has a row.
    static func prefillRows() -> [Row] {
        var rows: [Row] = []
        var next: EngineV2VisionPrefillError? = .unsupportedVLM("Wrapper")
        while let error = next, rows.count < 64 {
            switch error {
            case .unsupportedVLM:
                rows.append(.refused(error))
                next = .unsupportedMedia("a fixed detail")
            case .unsupportedMedia:
                rows.append(.clientFault(error))
                next = .noProcessedMedia
            case .noProcessedMedia:
                rows.append(.clientFault(error))
                next = .emptyVisionFeatures(kind: .image)
            case .emptyVisionFeatures:
                rows.append(.refused(error))
                next = .misalignedDeepstack(mediaIndex: 1)
            case .misalignedDeepstack:
                rows.append(.refused(error))
                next = .videoPlaceholderUnavailable
            case .videoPlaceholderUnavailable:
                rows.append(.refusedThoughArtifactOwned(error, .disabledVideoIsRetried))
                next = .conflictingPlaceholderIds(7)
            case .conflictingPlaceholderIds:
                rows.append(.refused(error))
                next = .placeholderRunMissing(kind: .image, mediaIndex: 0)
            case .placeholderRunMissing:
                rows.append(.refused(error))
                next = .placeholderRunTooShort(kind: .video, mediaIndex: 1, expected: 4)
            case .placeholderRunTooShort:
                rows.append(.refused(error))
                next = .unexpectedTrailingPlaceholders(kind: .image, count: 2)
            case .unexpectedTrailingPlaceholders:
                rows.append(.refused(error))
                next = .invalidFeatureLength(kind: .image, mediaIndex: 0, length: 0)
            case .invalidFeatureLength:
                rows.append(.refused(error))
                next = .invalidVisionGrid(mediaIndex: 0)
            case .invalidVisionGrid:
                rows.append(.refused(error))
                next = .visionPixelRunMismatch(expected: 10, actual: 8)
            case .visionPixelRunMismatch:
                rows.append(.refused(error))
                next = .towerBudgetExceeded(.artifact, "GLM aggregate patch limit")
            case .towerBudgetExceeded(.artifact, _):
                rows.append(.refusedThoughArtifactOwned(error, .artifactTowerLimitIsRetried))
                next = .towerBudgetExceeded(.operatorLimit, "GLM frame exceeds operator patch limit")
            case .towerBudgetExceeded(.operatorLimit, _):
                rows.append(.refused(error))
                next = .towerBudgetExceeded(.device, "GLM tower buffer exceeds Metal limit")
            case .towerBudgetExceeded(.device, _):
                rows.append(.refused(error))
                next = .towerAllocationRefused(requestedBytes: 2, limitBytes: 1)
            case .towerAllocationRefused:
                rows.append(.refused(error))
                next = .towerFault(stage: "vision prefill")
            case .towerFault:
                rows.append(.refused(error))
                next = nil
            }
        }
        precondition(next == nil, "the walk does not end")
        return rows
    }

    /// A reader that failed on both passes, for each medium: the media's fault,
    /// or this Mac's decoder when the code is a transient one.
    static func readerRows() -> [Row] {
        func failure(_ medium: VideoReaderFailure.Medium, _ code: AVError.Code) -> VideoReaderFailure {
            VideoReaderFailure(
                status: AVAssetReader.Status.failed.rawValue,
                error: NSError(domain: AVFoundationErrorDomain, code: code.rawValue), medium: medium)
        }
        return [VideoReaderFailure.Medium.video, .audio].flatMap { medium -> [Row] in
            switch medium {
            case .video, .audio:
                return [
                    .clientFault(failure(medium, .decodeFailed)),
                    .decodeUnavailable(failure(medium, .decoderTemporarilyUnavailable)),
                ]
            }
        }
    }

    /// One row per case of the processor's closed vocabulary, walked as above.
    static func processorRows() -> [Row] {
        var rows: [Row] = []
        var next: VLMError? = .imageRequired
        while let error = next, rows.count < 64 {
            switch error {
            case .imageRequired:
                rows.append(.clientFault(error))
                next = .maskRequired
            case .maskRequired:
                rows.append(.refused(error))
                next = .singleImageAllowed
            case .singleImageAllowed:
                rows.append(.clientFault(error))
                next = .singleVideoAllowed
            case .singleVideoAllowed:
                rows.append(.clientFault(error))
                next = .singleMediaTypeAllowed
            case .singleMediaTypeAllowed:
                rows.append(.clientFault(error))
                next = .imageProcessingFailure("a geometry")
            case .imageProcessingFailure:
                rows.append(.clientFault(error))
                next = .processing("a configuration")
            case .processing:
                rows.append(.refused(error))
                next = .noVideoTrackFound
            case .noVideoTrackFound:
                rows.append(.clientFault(error))
                next = .videoNotDecodable
            case .videoNotDecodable:
                rows.append(.clientFault(error))
                next = nil
            }
        }
        precondition(next == nil, "the walk does not end")
        return rows
    }

    /// One row per case of the ingest's own input faults, walked as above. They
    /// leave unchanged and keep their own failure codes.
    static func mediaErrorRows() -> [Row] {
        func row(_ error: MediaIngest.MediaError, _ code: InferenceFailureCode) -> Row {
            .passedThrough(error, Answer(status: 400, code: code, reason: nil), artifactOwned: true)
        }
        var rows: [Row] = []
        var next: MediaIngest.MediaError? = .malformedDataURI("a detail")
        while let error = next, rows.count < 64 {
            switch error {
            case .malformedDataURI:
                rows.append(row(error, .invalidMedia))
                next = .base64DecodeFailed
            case .base64DecodeFailed:
                rows.append(row(error, .invalidMedia))
                next = .percentDecodeFailed
            case .percentDecodeFailed:
                rows.append(row(error, .invalidMedia))
                next = .imageDecodeFailed
            case .imageDecodeFailed:
                rows.append(row(error, .invalidMedia))
                next = .invalidURL("https://example.invalid/a.png")
            case .invalidURL:
                rows.append(row(error, .invalidMedia))
                next = .mediaTooLarge("a limit")
            case .mediaTooLarge:
                rows.append(row(error, .mediaTooLarge))
                next = .unsupportedMedia("a rule")
            case .unsupportedMedia:
                rows.append(row(error, .unsupportedMedia))
                next = nil
            }
        }
        precondition(next == nil, "the walk does not end")
        return rows
    }

    /// Errors that already carry their answer and leave unchanged: the early
    /// first-content refusal, a cancel, and the engine's own errors (the Qwen
    /// pair's host memory refusal, the bridge's submit rejection, the media gate's).
    static let passedThroughRows: [Row] = [
        .passedThrough(
            PreContentDeadlineFailure.deadlineUnreachable,
            Answer(status: 503, code: .capacity, reason: .deadlineUnreachable)),
        .passedThrough(CancellationError(), Answer(status: 499, code: .cancelled, reason: .cancelled)),
        .passedThrough(
            MultiModelBatchSchedulerEngineError.tokenBudgetExhausted(
                "Qwen media host buffers exceed available memory"),
            Answer(status: 503, code: .capacity, reason: .tokenBudgetExhausted)),
        .passedThrough(
            MultiModelBatchSchedulerEngineError.multimodalRejected(
                "multimodal_rejected: invalid image spans (a detail)"),
            .clientFault, artifactOwned: true),
        .passedThrough(MultiModelBatchSchedulerEngineError.mediaMemoryUnavailable, .decodeUnavailable),
    ]

    /// Anything else is this provider's construction failure: an error no
    /// classification knows, a pair's own error, a GLM weight fault, a chat
    /// template that does not render.
    static let unclassifiedRows: [Row] = [
        .refused(MediaFailureUnclassifiedError()),
        .refused(DistributedEngineError.refused(.mediaUnsupported)),
        .refused(GLM5NextVisionError.weightsNotLoaded),
        .refusedThoughArtifactOwned(
            MediaFailureTemplateException(), .templateFailureKeepsTheRefusalStatus,
            answer: refusedTemplateFailure),
    ]
}

/// The pinned reason a route publishes no refusal event, or nil when it publishes them.
private func unpublishedRefusals(on route: MediaFailure.Route) -> KnownDivergence? {
    switch route {
    case .singleMac, .glmPair: return nil
    case .qwenPair: return .qwenPairPublishesNoRefusalTelemetry
    }
}

/// `error` through one route: what leaves it, and the refusal events it published.
private func drive(
    _ error: any Error, on route: MediaFailure.Route
) -> (outward: any Error, events: [TelemetryEvent]) {
    var events: [TelemetryEvent] = []
    let outward = MediaFailure.outward(
        error, route: route, modelId: "the-model", mediaKind: .video,
        emitTelemetry: { events.append($0) })
    return (outward, events)
}

@Suite("Media preparation failures keep one answer on every route")
struct MediaFailureDispositionTests {

    @Test("every error keeps the status, code and reason it has today")
    func everyErrorKeepsItsAnswer() {
        for row in Table.rows {
            for route in MediaFailure.Route.allCases {
                let answer = Answer(for: drive(row.error, on: route).outward)
                #expect(answer == row.pinned, "\(row.name) on \(route): \(answer), pinned \(row.pinned)")
            }
        }
    }

    @Test("an artifact-owned limit is a 400, capacity is a 429 or 503, and nothing is the generic 500")
    func ownershipDecidesTheAnswer() {
        for row in Table.rows {
            for route in MediaFailure.Route.allCases {
                let answer = Answer(for: drive(row.error, on: route).outward)
                let subject = "\(row.name) on \(route): \(answer)"
                if let divergence = row.divergence {
                    #expect(
                        answer.status != 400,
                        "\(divergence) no longer diverges for \(subject): remove it from KnownDivergence")
                } else if row.artifactOwned {
                    #expect(answer.status == 400, "\(subject)")
                }
                if answer.code == .capacity {
                    #expect([429, 503].contains(answer.status), "\(subject)")
                }
                #expect(answer.status != 500, "\(subject)")
            }
        }
    }

    @Test("the three routes agree, except that the Qwen pair publishes no refusal event")
    func theRoutesAgree() {
        for row in Table.rows {
            let reference = drive(row.error, on: .singleMac)
            #expect(reference.events.count == (row.publishesRefusal ? 1 : 0), "\(row.name)")
            for route in MediaFailure.Route.allCases {
                let driven = drive(row.error, on: route)
                #expect(
                    String(describing: driven.outward) == String(describing: reference.outward),
                    "\(row.name) on \(route)")
                let published = unpublishedRefusals(on: route) == nil ? reference.events.count : 0
                #expect(driven.events.count == published, "\(row.name) on \(route)")
            }
        }
    }

    @Test("a refusal event names the error's class, and its text only when that is content-safe")
    func refusalEventsCarryNoForeignText() throws {
        for row in Table.rows where row.publishesRefusal {
            let event = try #require(drive(row.error, on: .glmPair).events.first, "\(row.name)")
            let fields = try #require(event.fields)
            #expect(event.severity == .error && event.kind == .engineHealth, "\(row.name)")
            #expect(fields["operation"]?.description == "engine_v2_vision_refusal", "\(row.name)")
            #expect(fields["model"]?.description == "the-model", "\(row.name)")
            #expect(fields["media_kind"]?.description == "video", "\(row.name)")
            #expect(
                fields["error_class"]?.description == String(reflecting: type(of: row.error)),
                "\(row.name)")
            let contentSafe = row.error is EngineV2VisionPrefillError || row.error is VideoReaderFailure
            #expect(
                fields["error"]?.description == (contentSafe ? String(describing: row.error) : nil),
                "\(row.name)")
        }
    }

    @Test("a client fault keeps its fixed message")
    func clientFaultsKeepTheirMessages() {
        func message(_ error: any Error) -> String? {
            guard case .multimodalRejected(let message)? =
                drive(error, on: .singleMac).outward as? MultiModelBatchSchedulerEngineError
            else { return nil }
            return message
        }
        #expect(
            message(EngineV2VisionPrefillError.noProcessedMedia)
                == "multimodal_rejected: media parts must be attached to user messages; "
                + "none of this request's media was consumable")
        #expect(
            message(EngineV2VisionPrefillError.unsupportedMedia("a fixed detail"))
                == "multimodal_rejected: a fixed detail")
        #expect(
            message(VLMError.imageProcessingFailure("a geometry"))
                == "multimodal_rejected: the model's processor cannot resize this media "
                + "(a side below its minimum, an aspect ratio above its limit or no frame)")
        for error in [VLMError.noVideoTrackFound, .videoNotDecodable] {
            #expect(message(error) == "multimodal_rejected: the video has no decodable video track")
        }
        for error in [
            VLMError.imageRequired, .singleImageAllowed, .singleVideoAllowed, .singleMediaTypeAllowed,
        ] {
            #expect(
                message(error)
                    == "multimodal_rejected: the model's processor does not take this number or mix of media")
        }
    }

    @Test("a typed error leaves as the same error")
    func typedErrorsLeaveUnchanged() {
        for route in MediaFailure.Route.allCases {
            let engineError = MultiModelBatchSchedulerEngineError.tokenBudgetExhausted("a refusal")
            #expect(drive(engineError, on: route).outward as? MultiModelBatchSchedulerEngineError == engineError)
            #expect(
                drive(PreContentDeadlineFailure.deadlineUnreachable, on: route).outward
                    as? PreContentDeadlineFailure == .deadlineUnreachable)
            #expect(drive(CancellationError(), on: route).outward is CancellationError)
            let mediaError = drive(MediaIngest.MediaError.mediaTooLarge("a limit"), on: route).outward
            guard case .mediaTooLarge("a limit")? = mediaError as? MediaIngest.MediaError else {
                Issue.record("a MediaError changed on \(route): \(mediaError)")
                continue
            }
        }
    }

    @Test("a known divergence is still there", arguments: KnownDivergence.allCases)
    fileprivate func aKnownDivergenceStillDiverges(_ divergence: KnownDivergence) throws {
        let routes = MediaFailure.Route.allCases
        switch divergence {
        case .artifactTowerLimitIsRetried:
            let error = EngineV2VisionPrefillError.towerBudgetExceeded(.artifact, "GLM aggregate patch limit")
            for route in routes {
                #expect(Answer(for: drive(error, on: route).outward) == .constructionRefusal)
            }
        case .disabledVideoIsRetried:
            for route in routes {
                let outward = drive(EngineV2VisionPrefillError.videoPlaceholderUnavailable, on: route).outward
                #expect(Answer(for: outward) == .constructionRefusal)
            }
        case .pairImageRefusalIsUnmapped:
            // `clusterGLMImageIngress()` and `draftMiMoImageIngress()` throw this
            // from the scheduler's guards, outside any media catch.
            let refusal = DistributedEngineError.refused(.mediaUnsupported)
            #expect(Answer(for: refusal) == Answer(status: 500, code: .generationFailure, reason: nil))
            let submitted = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(
                EngineV2Translation.admissionErrorMessage(for: refusal))
            #expect(Answer(for: submitted) == Answer(status: 400, code: .invalidRequest, reason: .clientError))
        case .qwenPairPublishesNoRefusalTelemetry:
            let error = MediaFailureUnclassifiedError()
            #expect(drive(error, on: .singleMac).events.count == 1)
            #expect(drive(error, on: .glmPair).events.count == 1)
            #expect(drive(error, on: .qwenPair).events.isEmpty)
        case .superCapacityCoversDeterministicRefusals:
            // A grid past the tower's 13,312 patches fits no Mac, ever.
            #expect(throws: NemotronSuperLocalImageBinding.Failure.capacity) {
                try NemotronSuperLocalImageBinding.towerActivationBytes([(rows: 200, columns: 200)])
            }
            let outward = SuperHTTPErrors.map(NemotronSuperLocalImageBinding.Failure.capacity, media: true)
            #expect(Answer(for: outward) == .decodeUnavailable)
        case .templateFailureKeepsTheRefusalStatus:
            let failure = MediaFailureTemplateException()
            for route in routes {
                #expect(Answer(for: drive(failure, on: route).outward) == refusedTemplateFailure)
            }
            // The text path throws it as it is.
            #expect(Answer(for: failure) == Answer(status: 500, code: .templateRender, reason: .jinjaTemplate))
        }
    }

    @Test("the list of known divergences only shrinks")
    func knownDivergencesOnlyShrink() {
        #expect(
            KnownDivergence.allCases.count <= 6,
            "a new divergence is a change to the coordinator contract: review it, do not list it")
    }
}

/// GLM's vision tower configuration, with the fields a frame limit reads.
private func glmVisionConfiguration(
    numHeads: Int = 16, hiddenSize: Int = 1024, intermediateSize: Int = 4096
) throws -> GLM5NextVisionConfiguration {
    try JSONDecoder().decode(
        GLM5NextVisionConfiguration.self,
        from: Data(
            """
            {"model_type":"glm5_next_vision","depth":24,"hidden_size":\(hiddenSize),
             "intermediate_size":\(intermediateSize),"num_heads":\(numHeads),"out_hidden_size":4096,
             "patch_size":14,"projection_intermediate_size":10240,"spatial_merge_size":2,
             "temporal_patch_size":2,"in_channels":3,"attention_bias":true,"attention_dropout":0.0,
             "rms_norm_eps":1e-5,"swiglu_limit":10.0,"hidden_act":"silu","image_size":448,
             "initializer_range":0.02}
            """.utf8))
}

@Suite("A vision tower limit names who owns it")
struct MediaLimitOwnerTests {
    private struct Refusal: Equatable {
        let owner: MediaLimitOwner
        let detail: String
    }

    private func owner(_ decision: VisionTowerBudget.Decision) -> MediaLimitOwner? {
        guard case .reject(let owner, _) = decision else { return nil }
        return owner
    }

    /// A GPU whose largest buffer holds the attention of exactly 100 patches.
    private func limits(operatorMaxPatches: Int? = nil) -> VisionTowerBudget.Limits {
        .init(
            maxBufferBytes: 2 * 100 * 100, attentionElementBytes: 2, headFactor: 1,
            operatorMaxPatches: operatorMaxPatches)
    }

    @Test("the device owns what its buffer refuses; the operator only what a lower ceiling adds")
    func admissionNamesTheCeilingThatRefused() {
        func refused(_ patches: Int, _ limits: VisionTowerBudget.Limits) -> MediaLimitOwner? {
            owner(VisionTowerBudget.admit(patches: patches, subject: "this image", limits: limits))
        }
        #expect(refused(100, limits()) == nil)
        #expect(refused(101, limits()) == .device)
        #expect(refused(50, limits(operatorMaxPatches: 50)) == nil)
        #expect(refused(51, limits(operatorMaxPatches: 50)) == .operatorLimit)
        #expect(refused(100, limits(operatorMaxPatches: 50)) == .operatorLimit)
        // Both ceilings refuse it: the device would without the operator's.
        #expect(refused(101, limits(operatorMaxPatches: 50)) == .device)
        // A ceiling above the device's never binds.
        #expect(refused(101, limits(operatorMaxPatches: 1_000)) == .device)
        // No known device limit: only the operator's ceiling can refuse.
        let operatorOnly = VisionTowerBudget.Limits(
            maxBufferBytes: 0, attentionElementBytes: 2, headFactor: 1, operatorMaxPatches: 50)
        #expect(refused(51, operatorOnly) == .operatorLimit)
    }

    @Test("a grid whose patch count overflows is the artifact's on every Mac")
    func anUnrepresentableGridIsTheArtifacts() {
        #expect(
            owner(VisionTowerBudget.admit(grids: [THW(1, Int.max, 4)], subject: "this image", limits: limits()))
                == .artifact)
    }

    @Test("each GLM frame limit names its owner")
    func glmFrameLimitsNameTheirOwner() throws {
        func refusal(
            _ grid: THW, _ configuration: GLM5NextVisionConfiguration, _ limits: VisionTowerBudget.Limits
        ) throws -> Refusal? {
            do {
                _ = try VisionTowerBudget.glm5FrameLimits(grid: grid, configuration: configuration, limits: limits)
                return nil
            } catch EngineV2VisionPrefillError.towerBudgetExceeded(let owner, let detail) {
                return Refusal(owner: owner, detail: detail)
            }
        }
        func gpu(_ maxBufferBytes: Int, operatorMaxPatches: Int? = nil) -> VisionTowerBudget.Limits {
            .init(
                maxBufferBytes: maxBufferBytes, attentionElementBytes: 4, headFactor: 1,
                operatorMaxPatches: operatorMaxPatches)
        }
        let roomy = gpu(1 << 40)
        let shipped = try glmVisionConfiguration()
        let small = THW(1, 4, 4)
        // 31,680 patches: just under the tower's native 32,000.
        let large = THW(1, 180, 176)

        #expect(try refusal(large, shipped, roomy) == nil)
        #expect(
            try refusal(THW(1, 16, 16), shipped, gpu(1 << 40, operatorMaxPatches: 64))
                == Refusal(owner: .operatorLimit, detail: "GLM frame exceeds operator patch limit"))
        // A buffer too small for one query row, then one too small for the tower's buffers.
        #expect(
            try refusal(small, shipped, gpu(8))
                == Refusal(owner: .device, detail: "GLM attention query tile cannot fit"))
        #expect(
            try refusal(small, shipped, gpu(4096))
                == Refusal(owner: .device, detail: "GLM tower buffer exceeds Metal limit"))
        // An artifact with so many heads that one row passes the native tile on any GPU.
        #expect(
            try refusal(large, try glmVisionConfiguration(numHeads: 2048, hiddenSize: 8192), roomy)
                == Refusal(owner: .artifact, detail: "GLM attention query tile cannot fit"))
        // An artifact whose own dimensions overflow the byte arithmetic.
        #expect(
            try refusal(large, try glmVisionConfiguration(intermediateSize: 1 << 48), roomy)
                == Refusal(owner: .artifact, detail: "GLM frame byte overflow"))
    }
}
