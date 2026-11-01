import Foundation
import ImageIO
import DarkbloomClusterProtocol
import MLX
import MLXLMCommon
import MLXLMServer
import MLXVLM

extension DistributedQwenMediaIngress {
    /// Metadata first, then reserve before any raster or processor array. The
    /// awaited producer owns its transient charge even after cancellation.
    func prepare(request: OpenAIChatCompletionRequest, controls: ChatTemplateControls,
        tokenizer: any Tokenizer, hostBudget: GlobalKVCacheBudget
    ) async throws -> Prepared {
        try Task.checkCancellation()
        try MediaIngest.rejectUnsupportedAudio(request)
        guard let wireReservation = hostBudget.reserveHostBuffers(bytes: DistributedQwenMediaHostMemory.wireBytes) else {
            throw MultiModelBatchSchedulerEngineError.tokenBudgetExhausted("Qwen media host buffers exceed available memory")
        }
        // Inner scope owns all temporary encoded arrays. On failure it unwinds
        // fully before this function gives back the wire allowance.
        do {
            let description = try await prepareOwned(request: request, controls: controls,
                tokenizer: tokenizer, hostBudget: hostBudget)
            return .init(tokens: description.tokens,
                lifetime: .init(wire: description.wire, release: { wireReservation.closeAfterDroppingBuffers() }),
                mediaKind: description.mediaKind)
        } catch {
            wireReservation.closeAfterDroppingBuffers()
            throw error
        }
    }

    private func prepareOwned(request: OpenAIChatCompletionRequest, controls: ChatTemplateControls,
        tokenizer: any Tokenizer, hostBudget: GlobalKVCacheBudget
    ) async throws -> Description {
        let processor = try Qwen3VLMediaProcessor(modelConfiguration: configurationBytes,
            processorConfiguration: processorBytes)
        let sources = try await inspectSources(request, processor: processor)
        let bytes = try DistributedQwenMediaHostMemory.processingBytes(sources.map {
            .init(kind: $0.kind, decodedPixels: $0.decodedPixels, maximumPatches: $0.maximumPatches)
        }, maximumPromptTokens: maximumPromptTokens)
        guard let reservation = hostBudget.reserveHostBuffers(bytes: bytes) else {
            throw MultiModelBatchSchedulerEngineError.tokenBudgetExhausted("Qwen media preprocessing exceeds available memory")
        }
        let producer = Task {
            try await processAdmitted(request: request, controls: controls, tokenizer: tokenizer, sources: sources)
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await producer.value
            } onCancel: { producer.cancel() }
            reservation.closeAfterDroppingBuffers()
            return result
        } catch {
            reservation.closeAfterDroppingBuffers()
            throw error
        }
    }

    /// No raster decode. Original encoded inputs remain in product order and
    /// only inline media enters the existing ImageIO/AVFoundation path.
    private func inspectSources(_ request: OpenAIChatCompletionRequest,
        processor: Qwen3VLMediaProcessor
    ) async throws -> [Source] {
        var images: [Source] = [], videos: [Source] = []
        var encodedBytes = 0, imagePixels = 0, videoPixels = 0
        for message in request.messages {
            guard case .parts(let parts) = message.content else { continue }
            for part in parts {
                let kind: ClusterQwenMedia.Kind, uri: String
                switch part {
                case .imageURL(let value): kind = .image; uri = value
                case .videoURL(let value): kind = .video; uri = value
                default: continue
                }
                guard message.role == .user else {
                    throw EngineV2VisionPrefillError.unsupportedMedia("Qwen media must belong to user messages")
                }
                try Task.checkCancellation()
                guard (kind == .image ? images.count : videos.count)
                    < (kind == .image ? ClusterQwenMedia.maximumImages : ClusterQwenMedia.maximumVideos) else {
                    throw MediaIngest.MediaError.mediaTooLarge("Qwen media item count exceeds the pair limit")
                }
                let bytes = try MediaIngest.dataFromDataURI(uri)
                guard !bytes.isEmpty, bytes.count <= ClusterQwenMedia.maximumEncodedBytes - encodedBytes else {
                    throw MediaIngest.MediaError.mediaTooLarge("Qwen encoded media exceeds the pair limit")
                }
                encodedBytes += bytes.count
                if kind == .image {
                    let size = try Self.imageSize(bytes)
                    let grid = try processor.imageGrid(height: size.height, width: size.width)
                    guard let patches = VisionTowerBudget.patchCount(grid), patches > 0,
                        size.pixels <= min(ClusterQwenMedia.maximumKindPixels, MediaIngest.maxRequestImagePixels) - imagePixels else {
                        throw MediaIngest.MediaError.mediaTooLarge("Qwen aggregate image pixels exceed the pair limit")
                    }
                    imagePixels += size.pixels
                    images.append(.init(kind: kind, bytes: bytes, decodedPixels: size.pixels, maximumPatches: patches))
                } else {
                    // decodeVideo reads track metadata and creates a bounded
                    // in-memory asset; it does not decode or sample frames.
                    let metadata = try await MediaIngest.decodeVideo(uri,
                        maxFramePixels: min(ClusterQwenMedia.maximumItemPixels, MediaIngest.maxImagePixels))
                    guard metadata.framePixels > 0,
                        metadata.framePixels <= min(ClusterQwenMedia.maximumKindPixels,
                            MediaIngest.maxRequestVideoFramePixels) - videoPixels else {
                        throw MediaIngest.MediaError.mediaTooLarge("Qwen aggregate video pixels exceed the pair limit")
                    }
                    videoPixels += metadata.framePixels
                    videos.append(.init(kind: kind, bytes: bytes, decodedPixels: metadata.framePixels,
                        maximumPatches: try processor.maximumVideoPatchCount()))
                }
            }
        }
        guard !images.isEmpty || !videos.isEmpty else { throw EngineV2VisionPrefillError.noProcessedMedia }
        return images + videos
    }

    private static func imageSize(_ data: Data) throws -> (height: Int, width: Int, pixels: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
            width.doubleValue.isFinite, height.doubleValue.isFinite,
            width.doubleValue >= 1, height.doubleValue >= 1,
            width.doubleValue <= Double(ClusterQwenMedia.maximumItemPixels),
            height.doubleValue <= Double(ClusterQwenMedia.maximumItemPixels),
            width.doubleValue.rounded(.down) == width.doubleValue,
            height.doubleValue.rounded(.down) == height.doubleValue else {
            throw MediaIngest.MediaError.imageDecodeFailed
        }
        let w = width.intValue, h = height.intValue, product = w.multipliedReportingOverflow(by: h)
        guard !product.overflow, product.partialValue <= min(ClusterQwenMedia.maximumItemPixels, MediaIngest.maxImagePixels) else {
            throw MediaIngest.MediaError.mediaTooLarge("Qwen source image pixels exceed the pair limit")
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard (1...8).contains(orientation) else { throw MediaIngest.MediaError.imageDecodeFailed }
        return (5...8).contains(orientation) ? (w, h, product.partialValue) : (h, w, product.partialValue)
    }

    /// All decoded images, sampled frames and MLX patch/position arrays die
    /// within this awaited scope. The returned wire has a separate owner.
    private func processAdmitted(request: OpenAIChatCompletionRequest, controls: ChatTemplateControls,
        tokenizer: any Tokenizer, sources: [Source]
    ) async throws -> Description {
        try Task.checkCancellation()
        let nativeTools = configuration.modelType == "prism_hadamard_qwen35"
        let input = try await MediaIngest.buildUserInput(from: request, templateControls: controls,
            tools: nativeTools ? request.tools?.map { $0.toolSpec() } : nil,
            preserveTemplateFields: nativeTools, modelType: nativeTools ? configuration.modelType : nil,
            maxImagePixels: min(ClusterQwenMedia.maximumItemPixels, MediaIngest.maxImagePixels),
            maxRequestImagePixels: min(ClusterQwenMedia.maximumKindPixels, MediaIngest.maxRequestImagePixels),
            maxImagesPerRequest: min(ClusterQwenMedia.maximumImages, MediaIngest.maxImagesPerRequest),
            maxVideosPerRequest: min(ClusterQwenMedia.maximumVideos, MediaIngest.maxVideosPerRequest),
            maxRequestVideoFramePixels: min(ClusterQwenMedia.maximumKindPixels, MediaIngest.maxRequestVideoFramePixels))
        guard input.processing.resize == nil, input.processing.minPixels == nil, input.processing.maxPixels == nil else {
            throw EngineV2VisionPrefillError.unsupportedMedia("Qwen pair media requires the bound default processor policy")
        }
        let imageSources = sources.filter { $0.kind == .image }
        guard imageSources.count == input.images.count else { throw EngineV2VisionPrefillError.noProcessedMedia }
        for (source, image) in zip(imageSources, input.images) {
            let decoded = try image.asCIImage()
            guard MediaIngest.safeExtentPixels(decoded.extent) == source.decodedPixels else {
                throw MediaIngest.MediaError.mediaTooLarge("Qwen decoded image differs from its admitted header")
            }
        }
        return try await Device.withDefaultDevice(.cpu) {
            try await MLX.withError { (errors: MLX.ErrorBox) in
                let media = try Qwen3VLMediaProcessor(modelConfiguration: configurationBytes,
                    processorConfiguration: processorBytes)
                let prepared = try await media.makeUserInputProcessor(tokenizer: tokenizer).prepare(input: input)
                try EngineV2VisionPrefill.throwIfMLXFaulted(errors)
                try Task.checkCancellation()
                let value = try describe(prepared, sources: sources, mlxErrors: errors)
                try EngineV2VisionPrefill.throwIfMLXFaulted(errors)
                return value
            }
        }
    }
}
