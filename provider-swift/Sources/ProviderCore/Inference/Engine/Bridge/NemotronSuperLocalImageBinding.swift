import Foundation
import MLX
import MLXLMCommon
import MLXLMServer
import MLXVLM

/// Dedicated unpublished-owner image execution. No shared registry acquisition,
/// native consumer lease, prefix identity, MTP, or public route is manufactured.
/// The load owner retains this actor and drains it before retiring its bridge.
actor NemotronSuperLocalImageBinding {
    enum Failure: Error, Equatable {
        case closed, busy, wrongModel, unsupportedCapability, invalidInput, capacity, retainedFault
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

    func run(request: ChatCompletionRequest, input: Input,
             onEvent: @escaping @Sendable (GenerationEvent) async -> Void) async throws {
        guard !closing else { throw Failure.closed }
        guard active == nil else { throw Failure.busy }
        guard request.model == NemotronSuperLocalBinding.modelID else { throw Failure.wrongModel }
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
            try await Self.prepareAndExecute(owner: owner, makeInput: { _ in input }, featureBytes: quote.featureBytes,
                request: request, requestID: id, onEvent: onEvent)
        }
        try await settle(task, reservations: [mediaReservationID])
    }

    /// Inline base64 media under one of `admittedDataURIPrefixes`, rendered
    /// with this exact Owner's verified template/tokenizer.
    /// The body supplies media and request together; no separate media identity,
    /// caller-provided token counts, or URL fetching can be substituted.
    func runEncoded(body: Data, templateBytes: Data,
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
            let parsed = try Self.parseEncodedBody(body)
            let plan = try Self.encodedPlan(parsed.images, contextLength: gate.contextLength)
            let tokens = try owner.localImagePrompt(body: body, templateBytes: templateBytes,
                                                   featureCounts: plan.grids.map(\.tokens))
            guard await gate.reserve(requestId: mediaID, mediaDecodeBytes: plan.totalBytes, kvTokens: 0)
            else { throw Failure.capacity }
            try Task.checkCancellation()
            try await Self.prepareAndExecute(owner: owner, makeInput: { construction in
                var decoded: [NemotronSuperImageDecode.Prepared] = []
                for (index, data) in parsed.images.enumerated() {
                    try Task.checkCancellation()
                    let normalized = try NemotronSuperImageDecode.prepare(data, orientation: .applyEXIF,
                                                                          imageCount: parsed.images.count)
                    guard normalized.grid == plan.grids[index] else { throw Failure.invalidInput }
                    decoded.append(normalized)
                }
                // SDK helper owns raw array construction/reshape/eval in its own
                // fenced epoch, before the separate vision-preparation epoch.
                let input = try owner.makeLocalImageInput(promptTokens: tokens,
                    pixels: decoded.map(\.normalizedCHW), widths: plan.grids.map(\.width),
                    heights: plan.grids.map(\.height), construction: construction)
                let actual = try Self.preparationQuote(input, contextLength: gate.contextLength)
                guard actual.totalBytes <= plan.totalBytes, actual.featureBytes == plan.featureBytes else {
                    throw Failure.capacity
                }
                return input
            }, featureBytes: plan.featureBytes, request: parsed.request, requestID: id, onEvent: onEvent)
        }
        // No suspension precedes installing active: includes both admissions.
        try await settle(task, reservations: [ingressID, mediaID])
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

    private static func prepareAndExecute(owner: NemotronSuperLocalBridgeBuilder.Owner,
        makeInput: (NativeConstructionScope) throws -> Input, featureBytes: Int,
        request: ChatCompletionRequest, requestID: String,
        onEvent: @escaping @Sendable (GenerationEvent) async -> Void) async throws {
        let construction = NativeConstructionScope()
        let activity = owner.imageServiceBudget.beginUnboundedActivity()
        do {
            try Task.checkCancellation()
            let input = try makeInput(construction)
            let prepared = try owner.prepareLocalImage(input,
                maximumFeatureBytes: featureBytes, construction: construction)
            activity.finish()
            try Task.checkCancellation()
            try await execute(bridge: owner.bridge, prepared: prepared,
                request: request, requestID: requestID, onEvent: onEvent)
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
    }
    struct EncodedPlan {
        let grids: [NemotronSuperImagePreprocessing.Grid]
        let totalBytes: UInt64
        let featureBytes: Int
    }
    /// Small local ingress ceiling, separate from per-raster decode admission.
    /// Includes concurrent JSON/template/base64 copies and bounded metadata scratch.
    static func encodedHeaderQuote(bodyBytes: Int, templateBytes: Int) throws -> UInt64 {
        guard bodyBytes > 0, bodyBytes <= 8 * 1024 * 1024,
              templateBytes > 0, templateBytes <= 1024 * 1024 else { throw Failure.capacity }
        return UInt64(bodyBytes) * 32 + UInt64(templateBytes) * 4 + 16 * 1024 * 1024
    }

    /// Data-URI labels of the formats `NemotronSuperImageDecode` admits. The
    /// decoder sniffs content as the reference loader does, so a label only
    /// gates the URI shape: PNG bytes under the JPEG label decode as PNG.
    private static let admittedDataURIPrefixes = ["data:image/png;base64,", "data:image/jpeg;base64,"]

    /// Only call after encoded-header admission. Reuses existing inline decoder;
    /// a strict MIME/header gate excludes percent encoding and remote URLs.
    static func parseEncodedBody(_ body: Data) throws -> EncodedBody {
        struct Unsupported: Decodable {
            let logprobs: Bool?
            let top_logprobs: Int?
            let prompt_cache_key: String?
        }
        let flags = try JSONDecoder().decode(Unsupported.self, from: body)
        let request = try ProviderLoop.decodeOpenAIRequest(body)
        guard request.model == NemotronSuperLocalBinding.modelID else { throw Failure.wrongModel }
        guard request.tools == nil, request.toolChoice == nil, request.responseFormat == nil,
              request.parallelToolCalls == nil, request.toolCallParser == nil, request.minP == nil,
              flags.logprobs != true, flags.top_logprobs == nil, flags.prompt_cache_key == nil
        else { throw Failure.unsupportedCapability }
        var images: [Data] = []
        for message in request.messages {
            if case .parts(let parts) = message.content {
                for part in parts {
                    switch part {
                    case .text: break
                    case .imageURL(let uri):
                        guard images.count < 16, admittedDataURIPrefixes.contains(where: uri.hasPrefix) else {
                            throw Failure.unsupportedCapability
                        }
                        images.append(try MediaIngest.dataFromDataURI(uri))
                    default: throw Failure.unsupportedCapability
                    }
                }
            }
        }
        guard !images.isEmpty else { throw Failure.invalidInput }
        return EncodedBody(request: MultiModelBatchSchedulerEngine.translate(
            openAIRequest: request, defaultMaxTokens: 1), images: images)
    }

    static func encodedPlan(_ images: [Data], contextLength: Int) throws -> EncodedPlan {
        guard !images.isEmpty, images.count <= 16, contextLength > 0, contextLength <= 16384 else {
            throw Failure.invalidInput
        }
        var total: UInt64 = 0, features = 0, tokens = 0
        var grids: [NemotronSuperImagePreprocessing.Grid] = []
        for data in images {
            try Task.checkCancellation()
            let quote = try NemotronSuperImageDecode.inspect(data, orientation: .applyEXIF)
            let grid = try NemotronSuperImagePreprocessing.grid(width: quote.width, height: quote.height,
                                                               imageCount: images.count)
            guard grid.tokens <= contextLength - tokens else { throw Failure.capacity }
            tokens += grid.tokens
            let featureBytes = grid.tokens * 4096 * 4
            // Full SDK workspace plus BOTH retained CPU Float32 and MLX copies.
            let charge = UInt64(quote.normalizationWorkspaceBytes) + UInt64(grid.width * grid.height) * 24
                + UInt64(featureBytes)
            total = try sum(total, charge); features += featureBytes; grids.append(grid)
        }
        let activation = try towerActivationBytes(grids.map { ($0.heightPatches, $0.widthPatches) })
        return EncodedPlan(grids: grids, totalBytes: try sum(total, activation), featureBytes: features)
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
            contextLength > 0, contextLength <= 16384,
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

    private static func execute(bridge: EngineV2Bridge,
        prepared: EngineV2VisionPrefill.PreparedSubmission, request: ChatCompletionRequest,
        requestID: String, onEvent: @escaping @Sendable (GenerationEvent) async -> Void
    ) async throws {
        let usage = EngineV2RequestUsageSignal()
        await withTaskCancellationHandler {
            let stream = await bridge.submitTokenized(promptTokens: prepared.promptTokens,
                request: request, requestId: requestID, cacheScope: "", cacheEnabled: false,
                usageSignal: usage, multimodal: prepared.multimodalInput(), mediaKind: .image)
            for await event in stream {
                if Task.isCancelled { break }
                await onEvent(event)
            }
            if Task.isCancelled { await bridge.cancel(requestId: requestID) }
            await usage.waitForTerminalObservation()
        } onCancel: { Task { await bridge.cancel(requestId: requestID) } }
        try Task.checkCancellation()
    }
}
