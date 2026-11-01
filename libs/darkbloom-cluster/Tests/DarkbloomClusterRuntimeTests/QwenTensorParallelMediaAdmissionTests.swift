import CoreGraphics
import CoreImage
import DarkbloomClusterProtocol
import Foundation
import ImageIO
import MLX
import MLXLMCommon
import MLXVLM
import Testing
@testable import DarkbloomClusterRuntime

/// Rank zero's Qwen media patches against the leader's, and its admission.
/// The leader's half (`DistributedQwenMediaIngress`, provider) is reproduced
/// call for call: the product's ingest decode (`MediaIngest.decodeImageData`)
/// and the SDK's `Qwen3VLProcessor.prepare(input:)` on the CPU, each item's
/// digest taken from the prepared pixels' bytes. Rank zero's half is the
/// runtime's own `QwenMediaDecoding`. Synthetic images, encoded by ImageIO in
/// every format this Mac writes; the processor configuration is the Qwen 3.8
/// 27B artifact's (its preprocessor configuration over its processor
/// configuration). No model or tower; MLX on the CPU only.
@Suite(.serialized)
struct QwenTensorParallelMediaAdmissionTests {
    static let modelConfiguration = Data(#"{"model_type":"qwen3_5","image_token_id":60,"video_token_id":61,"vision_start_token_id":57,"vision_end_token_id":58,"text_config":{"model_type":"qwen3_5_text","hidden_size":8,"num_hidden_layers":1,"intermediate_size":16,"num_attention_heads":1,"num_key_value_heads":1,"head_dim":8,"linear_num_key_heads":1,"linear_num_value_heads":1,"linear_key_head_dim":8,"linear_value_head_dim":8,"linear_conv_kernel_dim":2,"vocab_size":64,"full_attention_interval":1},"vision_config":{"model_type":"qwen3_5_vision","depth":1,"hidden_size":8,"intermediate_size":16,"out_hidden_size":8,"num_heads":2,"patch_size":16,"spatial_merge_size":2,"temporal_patch_size":2,"num_position_embeddings":16,"in_channels":3,"hidden_act":"gelu_pytorch_tanh","deepstack_visual_indexes":[]}}"#.utf8)
    static let preprocessor = Data(#"{"size":{"longest_edge":16777216,"shortest_edge":65536},"patch_size":16,"temporal_patch_size":2,"merge_size":2,"image_mean":[0.5,0.5,0.5],"image_std":[0.5,0.5,0.5],"processor_class":"Qwen3VLProcessor","image_processor_type":"Qwen2VLImageProcessorFast"}"#.utf8)
    static let processor = Data(#"{"image_processor":{"do_convert_rgb":true,"do_normalize":true,"do_rescale":true,"image_mean":[0.5,0.5,0.5],"image_processor_type":"Qwen3VLImageProcessor","image_std":[0.5,0.5,0.5],"max_pixels":16777216,"merge_size":2,"min_pixels":65536,"patch_size":16,"rescale_factor":0.00392156862745098,"temporal_patch_size":2},"processor_class":"Qwen3VLProcessor","video_processor":{"do_convert_rgb":true,"do_normalize":true,"do_rescale":true,"fps":2.0,"image_mean":[0.5,0.5,0.5],"image_std":[0.5,0.5,0.5],"max_frames":768,"max_pixels":25165824,"merge_size":2,"min_frames":4,"min_pixels":4096,"patch_size":16,"rescale_factor":0.00392156862745098,"temporal_patch_size":2,"video_processor_type":"Qwen3VLVideoProcessor"}}"#.utf8)
    static let artifact = String(repeating: "a", count: 64)

    static func processorConfiguration() throws -> Data {
        try Qwen3VLMediaProcessor.resolvedConfiguration(preprocessor: preprocessor, processor: processor)
    }

    /// Saturated colours (JPEG chroma), a gradient and one-pixel stripes.
    static func raster(width: Int, height: Int) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let gradient = try #require(CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.1, green: 0.6, blue: 0.9, alpha: 1),
            CGColor(srgbRed: 0.95, green: 0.8, blue: 0.2, alpha: 1)] as CFArray, locations: [0, 1]))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: width / 10, y: height / 10, width: width / 4, height: height / 4))
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.2, blue: 0.9, alpha: 1))
        context.fillEllipse(in: CGRect(x: width / 2, y: height / 3, width: width / 3, height: height / 3))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        for x in stride(from: 0, to: width, by: 3) { context.fill(CGRect(x: x, y: 0, width: 1, height: height / 8)) }
        return try #require(context.makeImage())
    }

    /// The image in `type`, or nil when this Mac's ImageIO does not write it.
    static func encoded(_ image: CGImage, type: String) -> Data? {
        guard (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(type) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// `MediaIngest.decodeImageData`: the full image at index 0, its
    /// orientation applied, origin at zero.
    static func ingestDecode(_ data: Data) throws -> CIImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: true] as CFDictionary))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary))
        var decoded = CIImage(cgImage: image)
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let raw = properties[kCGImagePropertyOrientation] as? UInt32,
           let orientation = CGImagePropertyOrientation(rawValue: raw) {
            decoded = decoded.oriented(orientation)
        }
        let origin = decoded.extent.origin
        return origin == .zero ? decoded : decoded.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }

    struct Leader {
        let tokens: [Int]
        let grids: [THW]
        let digests: [String]
    }

    /// The leader's preparation (`DistributedQwenMediaIngress.processAdmitted`
    /// and `describe`): the product's prompt processor on the CPU device, each
    /// item's digest over its rows of the prepared pixels' bytes.
    static func leader(_ images: [Data]) async throws -> Leader {
        let decoded = try images.map { try ingestDecode($0) }
        let media = try Qwen3VLMediaProcessor(modelConfiguration: modelConfiguration,
            processorConfiguration: try processorConfiguration())
        let input = UserInput(chat: [.user("Describe.", images: decoded.map { UserInput.Image.ciImage($0) })])
        return try await Device.withDefaultDevice(.cpu) {
            try await MLX.withError { errors in
                let prepared = try await media.makeUserInputProcessor(tokenizer: QwenMediaFixtureTokenizer())
                    .prepare(input: input)
                try errors.check()
                let image = try #require(prepared.image)
                let frames = try #require(image.frames)
                eval(image.pixels, prepared.text.tokens); try errors.check()
                let bytes = image.pixels.asData(access: .noCopyIfContiguous).data
                let stride = ClusterQwenMedia.patchWidth * MemoryLayout<Float>.stride
                var digests: [String] = [], row = 0
                for grid in frames {
                    let rows = grid.t * grid.h * grid.w
                    digests.append(ClusterQwenMedia.sha256(bytes[(bytes.startIndex + row * stride)..<(bytes.startIndex + (row + rows) * stride)]))
                    row += rows
                }
                let tokens = prepared.text.tokens.asType(.int32).asArray(Int32.self).map(Int.init)
                try errors.check()
                return Leader(tokens: tokens, grids: frames, digests: digests)
            }
        }
    }

    /// The envelope the leader sends rank zero, positions included.
    static func envelope(_ images: [Data], _ leader: Leader, tamper: Bool = false) throws -> ClusterQwenMedia {
        let configuration = try JSONDecoder().decode(Qwen35Configuration.self, from: modelConfiguration)
        let seam = configuration.visionSeamConfiguration
        let positions = try Device.withDefaultDevice(.cpu) {
            try MLX.withError { errors in
                let result = try QwenVisionSeamSupport.positionResult(tokens: MLXArray(leader.tokens.map(Int32.init)),
                    imageGrids: leader.grids, videoGrids: nil, attentionMask: nil, seam: seam)
                eval(result.promptPositionIds); try errors.check()
                return (result.promptPositionIds.asArray(Int32.self), result.decodeState.deltas)
            }
        }
        var items: [ClusterQwenMedia.Item] = [], cursor = 0
        for (index, (data, grid)) in zip(images, leader.grids).enumerated() {
            let start = try #require(leader.tokens[cursor...].firstIndex(of: seam.visionStartTokenId)) + 1
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
            let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
            let count = grid.t * grid.h * grid.w / 4
            let digest = tamper && index == images.count - 1 ? String(repeating: "c", count: 64) : leader.digests[index]
            items.append(.init(kind: .image, sha256: ClusterQwenMedia.sha256(data), byteCount: data.count,
                decodedPixels: width * height, encoded: data, temporal: grid.t, height: grid.h, width: grid.w,
                tokenOffset: start, tokenCount: count, patchesSHA256: digest))
            cursor = start + count
        }
        return ClusterQwenMedia(artifactSHA256: artifact, configurationSHA256: ClusterQwenMedia.sha256(modelConfiguration),
            processorSHA256: ClusterQwenMedia.sha256(try processorConfiguration()), processorPolicy: .qwen35,
            promptLength: leader.tokens.count, promptSHA256: ClusterQwenMedia.int32SHA256(leader.tokens.map(Int32.init)),
            positionIDsSHA256: ClusterQwenMedia.int32SHA256(positions.0), decodeDeltas: positions.1, items: items)
    }

    static func work(_ media: ClusterQwenMedia, prompt: [Int]) throws -> QwenMediaRequestWork {
        let configuration = try JSONDecoder().decode(Qwen35Configuration.self, from: modelConfiguration)
        let identity = QwenMediaModelIdentity(artifactSHA256: artifact,
            configurationSHA256: ClusterQwenMedia.sha256(modelConfiguration),
            processorSHA256: ClusterQwenMedia.sha256(try processorConfiguration()),
            configuration: configuration, featureDType: .bfloat16)
        let state = try QwenMediaRequestState(media: media, prompt: prompt, identity: identity,
            maximumPrompt: 8192, maximumContext: 16384)
        let budget = try QwenMediaBudget(media: media, rank: 0, hiddenSize: 8, featureElementBytes: 2,
            maximumVideoPatches: 64, tensorParallel: true, chunkTokens: 128, minimumActivationBytes: 1024,
            maximumBufferBytes: Int.max, sealedFrameOverhead: 1024, allocationBound: { $0 })
        return QwenMediaRequestWork(state: state, budget: budget)
    }

    /// A CPU-stream task that fails while the stream runs it (a lazily loaded
    /// array whose file is gone when it is read), scheduled from another
    /// thread on the process's CPU stream and never waited for there.
    static func leaveFailedTaskOnTheProcessCPUStream() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen-media-admission-\(UUID().uuidString).safetensors")
        defer { try? FileManager.default.removeItem(at: url) }
        try MLX.save(arrays: ["x": MLXArray(Array(repeating: Float(1), count: 1 << 16))], url: url)
        let scheduled = DispatchSemaphore(value: 0)
        final class Outcome: @unchecked Sendable { var error: Error? }
        let outcome = Outcome()
        Thread {
            do {
                try MLX.withError { _ in
                    let loaded = try #require(try MLX.loadArrays(url: url, stream: .cpu)["x"])
                    let handle = try FileHandle(forWritingTo: url)
                    try handle.truncate(atOffset: 16); try handle.close()
                    asyncEval([MLX.multiply(loaded, MLXArray(Float(2)), stream: .cpu)])
                }
            } catch { outcome.error = error }
            scheduled.signal()
        }.start()
        scheduled.wait()
        if let error = outcome.error { throw error }
        // The read fails on the IO pool and the stream stores it.
        Thread.sleep(forTimeInterval: 0.2)
    }

    static let types = ["public.jpeg", "public.png", "com.compuserve.gif", "org.webmproject.webp", "public.heic"]

    @Test func rankZeroReproducesTheLeadersPatchesInEveryFormat() async throws {
        var covered: [String] = []
        for (width, height) in [(320, 256), (1000, 700), (112, 112)] {
            let image = try Self.raster(width: width, height: height)
            for type in Self.types {
                guard let data = Self.encoded(image, type: type) else { continue }
                let leader = try await Self.leader([data])
                let media = try Self.envelope([data], leader)
                let values = try await QwenMediaDecoding.prepare(media, modelConfiguration: Self.modelConfiguration,
                    processorConfiguration: try Self.processorConfiguration())
                #expect(values.map(QwenMediaDecoding.digest) == leader.digests, "\(type) \(width)x\(height)")
                covered.append("\(type)@\(width)x\(height)")
            }
        }
        // ImageIO writes these on every supported Mac; WebP and HEIC when it can.
        #expect(["public.jpeg", "public.png", "com.compuserve.gif"].allSatisfy { type in
            covered.contains { $0.hasPrefix(type + "@") }
        })
        // Two subjects of different formats and grids in one prompt.
        let jpeg = try #require(Self.encoded(try Self.raster(width: 320, height: 256), type: "public.jpeg"))
        let png = try #require(Self.encoded(try Self.raster(width: 1000, height: 700), type: "public.png"))
        let leader = try await Self.leader([jpeg, png])
        let values = try await QwenMediaDecoding.prepare(try Self.envelope([jpeg, png], leader),
            modelConfiguration: Self.modelConfiguration, processorConfiguration: try Self.processorConfiguration())
        #expect(leader.grids.count == 2 && values.map(QwenMediaDecoding.digest) == leader.digests)
        print("qwen-media-admission covered \(covered.joined(separator: " "))")
    }

    /// The pair's failure on c48: another thread's failed CPU-stream task is
    /// thrown to the next caller that synchronizes that stream. Rank zero's
    /// preparation synchronizes a stream of its own and is unaffected; the
    /// failure stays on the process stream, where the old preparation (the
    /// CPU device's stream, then `Stream.cpu.synchronize()`) receives it.
    @Test func anotherThreadsFailedCPUTaskCannotFailThePreparation() async throws {
        let data = try #require(Self.encoded(try Self.raster(width: 320, height: 256), type: "public.jpeg"))
        let leader = try await Self.leader([data])
        let media = try Self.envelope([data], leader)
        try Self.leaveFailedTaskOnTheProcessCPUStream()
        let values = try await QwenMediaDecoding.prepare(media, modelConfiguration: Self.modelConfiguration,
            processorConfiguration: try Self.processorConfiguration())
        #expect(values.map(QwenMediaDecoding.digest) == leader.digests)
        #expect(throws: MLXError.self) {
            try Device.withDefaultDevice(.cpu) {
                try MLX.withError { errors in
                    let value = MLXArray([Float(1), 2, 3]) + 1
                    eval(value); Stream.cpu.synchronize(); try errors.check()
                }
            }
        }
        // The process stream is clean again.
        try MLX.withError { errors in Stream.cpu.synchronize(); try errors.check() }
    }

    /// A preparation that differs from the leader refuses that request alone,
    /// with its reason, after its task ended; the next request is admitted
    /// with the leader's patches held as host values for its join.
    @Test func aDifferingPreparationRefusesItsRequestAndTheNextIsAdmitted() async throws {
        let data = try #require(Self.encoded(try Self.raster(width: 320, height: 256), type: "public.jpeg"))
        let leader = try await Self.leader([data])
        let processor = try Self.processorConfiguration()
        let refused = try Self.work(try Self.envelope([data], leader, tamper: true), prompt: leader.tokens)
        do {
            try QwenTensorParallelMedia.admit(refused, modelConfiguration: Self.modelConfiguration,
                processorConfiguration: processor, deadline: .max)
            Issue.record("A differing preparation was admitted")
        } catch let refusal as ClusterResidentRequestRefusal {
            #expect(refusal.reason == .unsupported)
            #expect(refusal.message.contains("patch bytes differ from the leader"))
        }
        #expect(refused.preparation.finished)
        #expect(throws: (any Error).self) { try refused.preparation.take() }
        try refused.releaseAfterCheckedDrain()

        let admitted = try Self.work(try Self.envelope([data], leader), prompt: leader.tokens)
        try QwenTensorParallelMedia.admit(admitted, modelConfiguration: Self.modelConfiguration,
            processorConfiguration: processor, deadline: .max)
        #expect(admitted.preparation.outcome == .prepared)
        #expect(try admitted.preparation.take().map(QwenMediaDecoding.digest) == leader.digests)
        try admitted.releaseAfterCheckedDrain()

        // Past its deadline: refused as `deadline`, its task ended first.
        let late = try Self.work(try Self.envelope([data], leader), prompt: leader.tokens)
        do {
            try QwenTensorParallelMedia.admit(late, modelConfiguration: Self.modelConfiguration,
                processorConfiguration: processor, deadline: 1)
            Issue.record("A preparation past its deadline was admitted")
        } catch let refusal as ClusterResidentRequestRefusal {
            #expect(refusal.reason == .deadline)
        }
        #expect(late.preparation.finished)
        try late.releaseAfterCheckedDrain()
    }
}

/// The Qwen chat template's media markers only: one
/// `<|vision_start|><|image_pad|><|vision_end|>` per image, as the product's
/// template renders them, every other character one ordinary token.
struct QwenMediaFixtureTokenizer: MLXLMCommon.Tokenizer {
    static let markers: [(String, Int)] = [("<|vision_start|>", 57), ("<|vision_end|>", 58),
        ("<|image_pad|>", 60), ("<|video_pad|>", 61)]
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        var tokens: [Int] = [], rest = Substring(text)
        while !rest.isEmpty {
            if let (marker, id) = Self.markers.first(where: { rest.hasPrefix($0.0) }) {
                tokens.append(id); rest = rest.dropFirst(marker.count)
            } else { tokens.append(4); rest = rest.dropFirst() }
        }
        return tokens
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { Self.markers.first { $0.0 == token }?.1 }
    func convertIdToToken(_ id: Int) -> String? { Self.markers.first { $0.1 == id }?.0 }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        var images = 0
        for message in messages {
            if let parts = message["content"] as? [[String: any Sendable]] {
                images += parts.filter { ($0["type"] as? String) == "image" }.count
            } else if let parts = message["content"] as? [[String: String]] {
                images += parts.filter { $0["type"] == "image" }.count
            }
        }
        return [1] + Array(repeating: encode(text: "<|vision_start|><|image_pad|><|vision_end|>",
            addSpecialTokens: false), count: images).flatMap { $0 } + [2]
    }
}
