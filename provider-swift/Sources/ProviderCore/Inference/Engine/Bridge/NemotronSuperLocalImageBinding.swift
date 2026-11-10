import Foundation
import MLX
import MLXLMCommon
import MLXLMServer
import MLXVLM

/// Dedicated owner media execution: inline images, or one inline video. No
/// shared registry acquisition, native consumer lease or MTP state is
/// manufactured; on a speculating owner the engine runs the request
/// target-only. A prefix identity is derived only from the request's own
/// evaluated features, and only with a cache scope. One media request runs
/// at a time. The load owner retains this actor and drains it before
/// retiring its bridge.
actor NemotronSuperLocalImageBinding {
    enum Failure: Error, Equatable {
        case closed, busy, wrongModel, invalidInput, capacity, retainedFault
        /// A `logprobs` request without the channel its entries leave on, or
        /// (test seam only) an output control the seam does not serve.
        case unsupportedCapability
        /// A media part of a kind, source or arrangement this route does
        /// not serve.
        case unsupportedMedia(MediaRefusal)
        /// The rendered prompt's media slots do not match the request's
        /// media: message text names `<image>` or `<video>` (the video prompt
        /// checks message text first), or a tool declaration, response-format
        /// instruction or other rendered text names `<image>` and adds or
        /// moves a slot. A request fault, as literal `<image>` is on the text
        /// route.
        case placeholderText
        /// The prompt with its visual tokens does not fit the context.
        case contextExceeded
        /// The encoded body exceeds `NemotronSuperServingPolicy.maximumEncodedBodyBytes`.
        case bodyTooLarge
        /// The tower and projector produced a non-finite feature.
        case invalidFeatures
        /// The video tower returned rows of another shape, or EVS pruning
        /// kept other rows than the prompt admitted.
        case inconsistentVideoFeatures
    }

    /// The media rules of this route. Each refusal names its rule in fixed
    /// text, never request content.
    enum MediaRefusal: Equatable, Sendable {
        case imageSource, videoSource, audio, partType, tooManyImages, imagesWithVideo, secondVideo

        var message: String {
            switch self {
            case .imageSource:
                "an image must be an inline base64 data: URI with an image/ media type"
            case .videoSource:
                "a video must be an inline base64 data: URI labelled video/mp4 or video/quicktime"
            case .audio: "this model takes no audio input"
            case .partType: "content parts must be text, image_url or video_url"
            case .tooManyImages:
                "a request carries at most \(NemotronSuperServingPolicy.maximumImages) images"
            case .imagesWithVideo: "a request carries images or one video, not both"
            case .secondVideo: "a request carries at most one video"
            }
        }
    }

    /// Internal qualification input. The caller must transfer immutable arrays
    /// from its admitted decoder and render tokens with this owner's tokenizer.
    /// Raw URL fetching/decoding is deliberately not provided by this boundary.
    struct Input: @unchecked Sendable {
        let promptTokens: [Int]
        let normalizedImages: [MLXArray]
    }

    private let owner: NemotronSuperLocalBridgeBuilder.Owner
    private let gate: VisionMemoryGate
    private var closing = false
    private var active: Task<Void, Error>?
    private var cancelActive: (@Sendable () -> Void)?

    /// Only the exact installed Owner creates this binding. There is no API
    /// accepting independently supplied installed model and bridge handles.
    init(owner: NemotronSuperLocalBridgeBuilder.Owner, budget: GlobalKVCacheBudget,
         contextLength: Int) {
        self.owner = owner
        self.gate = VisionMemoryGate(kvBudget: budget, fp16KVBytesPerToken: 0,
                                    contextLength: contextLength)
    }

    #if DEBUG
    /// TEST SEAM (debug builds only): pre-normalized input, which no
    /// production caller supplies. `cacheScope` partitions prefix reuse as
    /// for text (nil: none).
    func run(request: ChatCompletionRequest, input: Input, cacheScope: String? = nil,
             onEvent: @escaping @Sendable (GenerationEvent) async -> Void) async throws {
        guard !closing else { throw Failure.closed }
        guard active == nil else { throw Failure.busy }
        guard request.model == owner.modelID else { throw Failure.wrongModel }
        guard request.tools == nil, request.tool_choice == nil, request.response_format == nil,
            request.logprobs != true, request.top_logprobs == nil, request.prompt_cache_key == nil
        else { throw Failure.unsupportedCapability }
        let quote = try Self.preparationQuote(input, contextLength: gate.contextLength)
        let id = "super-local-image-" + UUID().uuidString
        // The bridge owns a second reservation under its request ID. Sharing
        // that key would make its KV admission look like a duplicate claim.
        let mediaReservationID = id + "-media"
        let owner = self.owner, gate = self.gate
        let task = Task<Void, Error> {
            try Task.checkCancellation()
            guard await gate.reserve(requestId: mediaReservationID, mediaDecodeBytes: quote.totalBytes, kvTokens: 0)
            else { throw Failure.capacity }
            try await Self.prepareAndExecute(owner: owner, prepare: { construction in
                try owner.prepareLocalImage(input, maximumFeatureBytes: quote.featureBytes,
                                            construction: construction)
            }, request: request, requestID: id, cacheScope: cacheScope, logprobs: nil, onEvent: onEvent)
        }
        try await settle(task, reservations: [mediaReservationID])
    }
    #endif

    /// Inline base64 media, images under any image label
    /// (`isInlineBase64Image`) or one video under
    /// `admittedVideoDataURIPrefixes`, rendered with this exact
    /// Owner's verified template/tokenizer from `plan`, the body's request
    /// plan, as the text route renders it: tools, tool choice and the
    /// response format reach the prompt, and the caller's output parser
    /// (`NemotronSuperLocalOutput`, from the same plan) validates the answer.
    /// The body supplies media and request together; no separate media
    /// identity, caller-provided token counts, or URL fetching can be
    /// substituted. A `logprobs` request needs the `logprobs` channel its
    /// entries leave on.
    func runEncoded(body: Data, plan: NemotronSuperRequestPlan, templateBytes: Data,
                    cacheScope: String? = nil, logprobs: EngineV2LogprobsChannel? = nil,
                    onEvent: @escaping @Sendable (GenerationEvent) async -> Void) async throws {
        guard !closing else { throw Failure.closed }
        guard active == nil else { throw Failure.busy }
        let headerBytes = try Self.encodedHeaderQuote(bodyBytes: body.count, templateBytes: templateBytes.count)
        let id = "super-local-encoded-" + UUID().uuidString
        let ingressID = id + "-ingress", mediaID = id + "-media"
        let owner = self.owner, gate = self.gate
        let task = Task<Void, Error> {
            try Task.checkCancellation()
            // Before JSON/base64/header expansion, using the real shared ledger.
            guard await gate.reserve(requestId: ingressID, mediaDecodeBytes: headerBytes, kvTokens: 0)
            else { throw Failure.capacity }
            let parsed = try Self.encodedBody(plan)
            guard parsed.request.logprobs != true || logprobs != nil else { throw Failure.unsupportedCapability }
            if let video = parsed.video {
                try await VideoReaderFailureReport.reporting(to: { TelemetryClient.shared.emit($0) }) {
                    try await Self.executeEncodedVideo(video, plan: plan, body: body, templateBytes: templateBytes,
                        request: parsed.request, owner: owner, gate: gate, mediaID: mediaID, requestID: id,
                        cacheScope: cacheScope, logprobs: logprobs, onEvent: onEvent)
                }
                return
            }
            let imagePlan = try Self.encodedPlan(parsed.images, contextLength: gate.contextLength)
            let tokens = try owner.localImagePrompt(plan: plan, body: body, templateBytes: templateBytes,
                                                   featureCounts: imagePlan.grids.map(\.tokens))
            guard await gate.reserve(requestId: mediaID, mediaDecodeBytes: imagePlan.totalBytes, kvTokens: 0)
            else { throw Failure.capacity }
            try Task.checkCancellation()
            try await Self.prepareAndExecute(owner: owner, prepare: { construction in
                var decoded: [NemotronSuperImageDecode.Prepared] = []
                for image in imagePlan.images {
                    try Task.checkCancellation()
                    decoded.append(try NemotronSuperImageDecode.prepare(image))
                }
                // SDK helper owns raw array construction/reshape/eval in its own
                // fenced epoch, before the separate vision-preparation epoch.
                let input = try owner.makeLocalImageInput(promptTokens: tokens,
                    pixels: decoded.map(\.normalizedCHW), widths: imagePlan.grids.map(\.width),
                    heights: imagePlan.grids.map(\.height), construction: construction)
                let actual = try Self.preparationQuote(input, contextLength: gate.contextLength)
                guard actual.totalBytes <= imagePlan.totalBytes, actual.featureBytes == imagePlan.featureBytes else {
                    throw Failure.capacity
                }
                return try owner.prepareLocalImage(input, maximumFeatureBytes: imagePlan.featureBytes,
                                                   construction: construction)
            }, request: parsed.request, requestID: id, cacheScope: cacheScope, logprobs: logprobs,
               onEvent: onEvent)
        }
        // No suspension precedes installing active: includes both admissions.
        try await settle(task, reservations: [ingressID, mediaID])
    }

    /// One inline video under the ingress reservation: its compressed samples
    /// plan the frames and labels, the prompt is rendered and admitted at its
    /// final length, and the whole charge (`encodedVideoPlan`) is reserved
    /// before any frame decodes. Frames then decode one at a time into the
    /// tower's tubelet batches; cancelling the request, as `drain` does,
    /// ends a wait on the decoder at once, and the reader stops once the read
    /// in progress returns.
    private static func executeEncodedVideo(_ uri: String, plan requestPlan: NemotronSuperRequestPlan,
        body: Data, templateBytes: Data,
        request: ChatCompletionRequest, owner: NemotronSuperLocalBridgeBuilder.Owner, gate: VisionMemoryGate,
        mediaID: String, requestID: String, cacheScope: String?, logprobs: EngineV2LogprobsChannel?,
        onEvent: @escaping @Sendable (GenerationEvent) async -> Void) async throws {
        let video = try await NemotronSuperVideoDecode.inspect(uri)
        let prompt = try owner.localVideoPrompt(plan: requestPlan, body: body, templateBytes: templateBytes,
                                                labels: video.labels)
        let plan = try encodedVideoPlan(video, prompt: prompt, pruningRate: owner.videoPruningRate,
                                        contextLength: gate.contextLength)
        guard await gate.reserve(requestId: mediaID, mediaDecodeBytes: plan.totalBytes, kvTokens: 0)
        else { throw Failure.capacity }
        try Task.checkCancellation()
        try await prepareAndExecute(owner: owner, prepare: { construction in
            let frames = try await NemotronSuperVideoDecode.Frames(video)
            return try await frames.withCancellableReader {
                try owner.prepareLocalVideo(frames, prompt: prompt, maximumFeatureBytes: plan.featureBytes,
                                            construction: construction)
            }
        }, request: request, requestID: requestID, cacheScope: cacheScope, logprobs: logprobs, onEvent: onEvent)
    }

    /// Cleanup coordinator holds no image arrays. Actual work task completion
    /// drops its captures before refund. drain awaits this same cleanup task.
    private func settle(_ work: Task<Void, Error>, reservations: [String]) async throws {
        let owner = self.owner, gate = self.gate
        let cleanup = Task<Void, Error> {
            let result = await work.result
            if !owner.hasRetainedImageFault {
                for id in reservations { await gate.release(requestId: id) }
            }
            try result.get()
        }
        active = cleanup
        cancelActive = { work.cancel() }
        defer { active = nil; cancelActive = nil }
        try await withTaskCancellationHandler {
            try await cleanup.value
        } onCancel: { work.cancel() }
    }

    /// `prepare` builds the evaluated submission in `construction`; a
    /// retained fault there quarantines the owner with this request's charge.
    private static func prepareAndExecute(owner: NemotronSuperLocalBridgeBuilder.Owner,
        prepare: (NativeConstructionScope) async throws -> EngineV2VisionPrefill.PreparedSubmission,
        request: ChatCompletionRequest, requestID: String, cacheScope: String?,
        logprobs: EngineV2LogprobsChannel?,
        onEvent: @escaping @Sendable (GenerationEvent) async -> Void) async throws {
        let construction = NativeConstructionScope()
        let activity = owner.imageServiceBudget.beginUnboundedActivity()
        do {
            try Task.checkCancellation()
            let prepared = try await prepare(construction)
            activity.finish()
            try Task.checkCancellation()
            try await execute(bridge: owner.bridge, prepared: prepared,
                cacheScope: owner.prefixBankBytes > 0 ? cacheScope : nil,
                request: request, requestID: requestID, logprobs: logprobs, onEvent: onEvent)
        } catch {
            if construction.snapshot.isRetainedFault {
                owner.quarantineLocalImage(construction: construction, activity: activity)
                throw Failure.retainedFault
            }
            activity.finish()
            throw error
        }
    }

    struct EncodedBody {
        let request: ChatCompletionRequest
        let images: [Data]
        /// The one video's data URI, still encoded; then `images` is empty.
        var video: String? = nil
    }
    struct EncodedPlan {
        /// Each image as planned; preparation decodes from these parses.
        let images: [NemotronSuperImageDecode.Plan]
        let totalBytes: UInt64
        let featureBytes: Int
        var grids: [NemotronSuperImagePreprocessing.Grid] { images.map(\.grid) }
    }
    /// Local ingress ceiling, separate from per-raster decode admission.
    /// Includes concurrent JSON/template/base64 copies and bounded metadata scratch.
    /// No retry fits a body or template outside the bounds: a body above
    /// `NemotronSuperServingPolicy.maximumEncodedBodyBytes` is refused as too
    /// large, any other as invalid.
    static func encodedHeaderQuote(bodyBytes: Int, templateBytes: Int) throws -> UInt64 {
        guard bodyBytes > 0, templateBytes > 0, templateBytes <= 1024 * 1024 else { throw Failure.invalidInput }
        guard bodyBytes <= NemotronSuperServingPolicy.maximumEncodedBodyBytes else { throw Failure.bodyTooLarge }
        return UInt64(bodyBytes) * 32 + UInt64(templateBytes) * 4 + 16 * 1024 * 1024
    }

    /// An inline base64 image: `data:image/<subtype>[;attribute=value]...;base64,`.
    /// `NemotronSuperImageDecode` takes the format from the bytes, as the
    /// reference loader and the coordinator's fetch do, so the label gates
    /// only the URI's shape and kind: any image subtype, in any case (RFC
    /// 2045), such as the `image/jpg` alias clients send. A remote or file
    /// URL, percent encoding, a label that is not an image, and a header
    /// above 256 bytes are refused. `data:` and `;base64` are matched as
    /// written, as the coordinator and `MediaIngest.dataFromDataURI` read them.
    static func isInlineBase64Image(_ uri: String) -> Bool {
        guard let comma = uri.utf8.firstIndex(of: UInt8(ascii: ",")) else { return false }
        let header = uri[..<comma]
        guard header.utf8.count <= 256, header.hasPrefix("data:"), header.hasSuffix(";base64") else { return false }
        let fields = header.dropFirst("data:".count).dropLast(";base64".count)
            .split(separator: ";", omittingEmptySubsequences: false)
        let type = fields[0].split(separator: "/", omittingEmptySubsequences: false)
        guard type.count == 2, type[0].lowercased() == "image", isToken(type[1]) else { return false }
        return fields.dropFirst().allSatisfy { parameter in
            let pair = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return pair.count == 2 && isToken(pair[0]) && isToken(pair[1])
        }
    }

    /// An RFC 2045 token: printable ASCII without spaces or `tspecials`.
    private static func isToken(_ text: Substring) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { byte in
            byte > 0x20 && byte < 0x7f && !"()<>@,;:\\\"/[]?=".utf8.contains(byte)
        }
    }

    /// The inline movie labels `MediaIngest.decodeVideo` admits.
    private static let admittedVideoDataURIPrefixes = ["data:video/mp4;base64,", "data:video/quicktime;base64,"]

    /// The media of a request its `plan` admitted; only call after
    /// encoded-header admission. The plan validated every request control, as
    /// on the text route, so only the media rules apply here: a strict
    /// MIME/header gate excludes percent encoding and remote URLs, and a video
    /// is the only media of its request. It stays encoded here.
    static func encodedBody(_ plan: NemotronSuperRequestPlan) throws -> EncodedBody {
        var images: [Data] = []
        var video: String?
        for message in plan.request.messages {
            if case .parts(let parts) = message.content {
                for part in parts {
                    switch part {
                    case .text: break
                    case .imageURL(let uri):
                        guard video == nil else { throw Failure.unsupportedMedia(.imagesWithVideo) }
                        guard images.count < NemotronSuperServingPolicy.maximumImages
                        else { throw Failure.unsupportedMedia(.tooManyImages) }
                        guard isInlineBase64Image(uri) else { throw Failure.unsupportedMedia(.imageSource) }
                        images.append(try MediaIngest.dataFromDataURI(uri))
                    case .videoURL(let uri):
                        guard images.isEmpty else { throw Failure.unsupportedMedia(.imagesWithVideo) }
                        guard video == nil else { throw Failure.unsupportedMedia(.secondVideo) }
                        guard admittedVideoDataURIPrefixes.contains(where: uri.hasPrefix)
                        else { throw Failure.unsupportedMedia(.videoSource) }
                        video = uri
                    case .inputAudio: throw Failure.unsupportedMedia(.audio)
                    case .unsupported: throw Failure.unsupportedMedia(.partType)
                    }
                }
            }
        }
        guard !images.isEmpty || video != nil else { throw Failure.invalidInput }
        return EncodedBody(request: plan.bridgeRequest, images: images, video: video)
    }

    static func encodedPlan(_ images: [Data], contextLength: Int) throws -> EncodedPlan {
        guard !images.isEmpty, images.count <= NemotronSuperServingPolicy.maximumImages, contextLength > 0,
            contextLength <= NemotronSuperServingPolicy.maximumContextTokens else {
            throw Failure.invalidInput
        }
        var retained: UInt64 = 0, workspace: UInt64 = 0, features = 0, tokens = 0
        var planned: [NemotronSuperImageDecode.Plan] = []
        for data in images {
            try Task.checkCancellation()
            // Refuses an oversize resize workspace before any reservation or decode.
            let image = try NemotronSuperImageDecode.plan(data, orientation: .applyEXIF, imageCount: images.count)
            let grid = image.grid
            // Visual tokens beyond the context are the request's own fault.
            guard grid.tokens <= contextLength - tokens else { throw Failure.contextExceeded }
            tokens += grid.tokens
            let featureBytes = grid.tokens * 4096 * 4
            // Images decode and normalize one at a time, so the largest decoder
            // and full SDK workspace is charged once; BOTH retained CPU Float32
            // and MLX copies and the features are charged for every image.
            workspace = max(workspace, UInt64(image.quote.normalizationWorkspaceBytes))
            retained = try sum(retained, UInt64(grid.width * grid.height) * 24 + UInt64(featureBytes))
            features += featureBytes; planned.append(image)
        }
        let activation = try towerActivationBytes(planned.map { ($0.grid.heightPatches, $0.grid.widthPatches) })
        return EncodedPlan(images: planned, totalBytes: try sum(try sum(retained, workspace), activation),
                           featureBytes: features)
    }

    /// Tower and projector working memory of the largest image: preparation
    /// evaluates images one at a time. Owners install only the pinned Super VL
    /// composition, so its derived bound applies; it is added to, not taken
    /// from, the global activation reserve. The SDK marks a grid it would
    /// refuse with `Int.max`, which is refused here as capacity.
    static func towerActivationBytes(_ grids: [(rows: Int, columns: Int)]) throws -> UInt64 {
        let largest = grids.map {
            NemotronSuperImageComposition.pinnedActivationBytes(patchRows: $0.rows, patchColumns: $0.columns)
        }.max() ?? 0
        guard largest < Int.max else { throw Failure.capacity }
        return UInt64(largest)
    }

    struct EncodedVideoPlan {
        let totalBytes: UInt64
        /// Float32 storage of every row pruning keeps.
        let featureBytes: Int
    }

    /// The video's charge and kept-row grant, after its prompt fits the
    /// context at its final length: pruning fixes the kept count, and any
    /// split of it across tubelets gives the same length.
    static func encodedVideoPlan(_ video: NemotronSuperVideoDecode.Plan,
        prompt: NemotronSuperPromptContract.VideoPrompt, pruningRate: Double,
        contextLength: Int) throws -> EncodedVideoPlan {
        guard contextLength > 0, contextLength <= NemotronSuperServingPolicy.maximumContextTokens,
            video.tubelets > 0, prompt.labels.count == video.tubelets
        else { throw Failure.invalidInput }
        let rows = NemotronSuperVideoFeatures.retainedRows(tubelets: video.tubelets,
            rowsPerTubelet: video.grid.tokens, pruningRate: pruningRate)
        do {
            _ = try prompt.tokens(keptCounts: [rows] + Array(repeating: 0, count: video.tubelets - 1),
                                  contextLength: contextLength)
        } catch NemotronSuperPromptContract.Failure.contextExceeded {
            // A video prompt beyond the context is the request's own fault.
            throw Failure.contextExceeded
        }
        let total = try videoChargeBytes(encodedBytes: video.encodedBytes, codedPixels: video.codedPixels,
            patchRows: video.grid.heightPatches, patchColumns: video.grid.widthPatches,
            tubelets: video.tubelets)
        return EncodedVideoPlan(totalBytes: total, featureBytes: rows * 4096 * 4)
    }

    /// What one video request holds beyond its ingress quote, for frames of
    /// `patchRows` x `patchColumns` 16-pixel patches: two decoded copies of
    /// the movie; the decoder's working set at its coded frame size; one
    /// tubelet batch's normalized frames (CPU and MLX copies) and tower
    /// activation; its EVS scoring window, the batch behind the previous
    /// batch's last tubelet (`NemotronSuperServingPolicy.videoScoringBytesPerRow`);
    /// and every tubelet's projected rows
    /// (`NemotronSuperServingPolicy.videoBytesPerFeatureRow`). Frames decode
    /// as each batch is filled, so no other frame is resident.
    static func videoChargeBytes(encodedBytes: Int, codedPixels: Int, patchRows: Int, patchColumns: Int,
                                 tubelets: Int) throws -> UInt64 {
        typealias Policy = NemotronSuperServingPolicy
        guard encodedBytes >= 0, codedPixels > 0, tubelets > 0,
            tubelets <= (NemotronSuperVideoPreprocessing.maximumFrames + 1) / 2,
            patchRows > 0, patchColumns > 0, patchRows % 2 == 0, patchColumns % 2 == 0,
            patchRows <= Policy.maximumVideoGridPatches, patchColumns <= Policy.maximumVideoGridPatches,
            patchRows * patchColumns <= Policy.maximumVideoGridPatches
        else { throw Failure.invalidInput }
        let patches = patchRows * patchColumns
        let batch = UInt64(min(tubelets, NemotronSuperVideoFeatures.tubeletBatch))
        let window = UInt64(min(tubelets, NemotronSuperVideoFeatures.tubeletBatch + 1))
        let activation = NemotronSuperImageComposition.pinnedTubeletActivationBytes(
            patchRows: patchRows, patchColumns: patchColumns)
        guard activation < Int.max else { throw Failure.capacity }
        // Two frames of 256 RGB Float32 pixels per patch, CPU and MLX copies.
        let tubeletFrames = try product(UInt64(patches), 2 * 256 * 3 * 4 * 2)
        var total = try product(UInt64(encodedBytes), 2)
        total = try sum(total, try product(UInt64(codedPixels), Policy.videoDecodeBytesPerCodedPixel))
        total = try sum(total, Policy.videoDecodeAllowanceBytes)
        total = try sum(total, try product(batch, try sum(tubeletFrames, UInt64(activation))))
        total = try sum(total, try product(window * UInt64(patches / 4), Policy.videoScoringBytesPerRow))
        return try sum(total, try product(UInt64(tubelets * patches / 4), Policy.videoBytesPerFeatureRow))
    }

    func drain() async throws {
        closing = true
        let pending = active
        cancelActive?()
        _ = await pending?.result
        guard !owner.hasRetainedImageFault else { throw Failure.retainedFault }
    }

    struct Quote {
        let totalBytes: UInt64
        let featureBytes: Int
    }

    /// Charges retained normalized inputs, final float32 feature storage and
    /// the largest image's derived tower activation bound. The unchanged global
    /// budget retains its conservative activation reserve. Bridge KV is separate.
    static func preparationQuote(_ input: Input, contextLength: Int) throws -> Quote {
        guard !input.promptTokens.isEmpty, input.promptTokens.count <= contextLength,
            contextLength > 0, contextLength <= NemotronSuperServingPolicy.maximumContextTokens,
            input.promptTokens.allSatisfy({ (0..<131072).contains($0) }),
            !input.normalizedImages.isEmpty else { throw Failure.invalidInput }
        let visualTokens = input.promptTokens.filter { $0 == 18 }.count
        guard visualTokens > 0 else { throw Failure.invalidInput }
        let (features, overflow) = visualTokens.multipliedReportingOverflow(by: 4096 * 4)
        guard !overflow else { throw Failure.capacity }
        var total = UInt64(features)
        for pixels in input.normalizedImages {
            guard pixels.ndim == 4, pixels.dim(0) == 1, pixels.dim(1) > 0, pixels.dim(1) <= 4,
                pixels.dim(2) > 0, pixels.dim(3) > 0,
                [.float32, .float16, .bfloat16].contains(pixels.dtype)
            else { throw Failure.invalidInput }
            let (bytes, byteOverflow) = UInt64(pixels.size).multipliedReportingOverflow(by: 4)
            let (next, sumOverflow) = total.addingReportingOverflow(bytes)
            guard !byteOverflow, !sumOverflow else { throw Failure.capacity }
            total = next
        }
        let patch = 16
        let activation = try towerActivationBytes(input.normalizedImages.map {
            (($0.dim(2) + patch - 1) / patch, ($0.dim(3) + patch - 1) / patch)
        })
        return Quote(totalBytes: try sum(total, activation), featureBytes: features)
    }

    private static func sum(_ total: UInt64, _ charge: UInt64) throws -> UInt64 {
        let (next, overflow) = total.addingReportingOverflow(charge)
        guard !overflow else { throw Failure.capacity }
        return next
    }

    private static func product(_ value: UInt64, _ factor: UInt64) throws -> UInt64 {
        let (next, overflow) = value.multipliedReportingOverflow(by: factor)
        guard !overflow else { throw Failure.capacity }
        return next
    }

    /// With a `cacheScope` (the owner has a checkpoint bank), the request is
    /// bound to an identity of its evaluated features and spans, hashed while
    /// the media charge still covers the copy, and may restore only
    /// checkpoints of that identity in that scope; without one it stays cold
    /// and never publishes.
    private static func execute(bridge: EngineV2Bridge,
        prepared: EngineV2VisionPrefill.PreparedSubmission, cacheScope: String?,
        request: ChatCompletionRequest, requestID: String, logprobs: EngineV2LogprobsChannel?,
        onEvent: @escaping @Sendable (GenerationEvent) async -> Void
    ) async throws {
        let usage = EngineV2RequestUsageSignal()
        let identity = cacheScope == nil ? nil : try prepared.hybridPrefixIdentity()
        await withTaskCancellationHandler {
            let stream = await bridge.submitTokenized(promptTokens: prepared.promptTokens,
                request: request, requestId: requestID, cacheScope: cacheScope ?? "",
                cacheEnabled: identity != nil, usageSignal: usage,
                multimodal: prepared.multimodalInput(), hybridPrefixIdentity: identity,
                mediaKind: prepared.mediaKind)
            for await event in stream {
                if Task.isCancelled { break }
                // The bridge yields a delta's entries just before its text;
                // they leave on the request's channel in that order.
                if case .logprobs(let entries) = event { logprobs?.append(entries); continue }
                await onEvent(event)
            }
            if Task.isCancelled { await bridge.cancel(requestId: requestID) }
            await usage.waitForTerminalObservation()
        } onCancel: { Task { await bridge.cancel(requestId: requestID) } }
        try Task.checkCancellation()
    }
}
