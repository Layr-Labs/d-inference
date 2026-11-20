// Copyright © 2026 Eigen Labs.
//
// A Qwen request past its image budget that also carries a clip: the image
// share (`imagePixelTarget`, `UserInput.Processing.maxPixels`) sizes only the
// images, and the clip keeps its video budget (`videoProcessing`,
// `UserInput.Processing.video`). Runs the real `Qwen3VLProcessor` and the
// pair's single-block processor with a stub tokenizer: no weights, no network.

import CoreImage
import CoreMedia
import Foundation
import MLX
import MLXLMCommon
import MLXLMServer
import Testing

@testable import MLXVLM
@testable import ProviderCore

@Suite("Qwen video with the image budget")
struct QwenVideoImageBudgetTests {

    static let model = "EigenLabs/Qwen3.8-27B-4bit-mtp"
    static let images = 20

    /// Special tokens by id; every other character encodes to its scalar plus
    /// an offset, so decode and encode round-trip.
    struct StubTokenizer: MLXLMCommon.Tokenizer {
        let images: Int
        let videos: Int

        static let specials = [
            "<|vision_start|>": 248_053, "<|vision_end|>": 248_054,
            "<|image_pad|>": 248_056, "<|video_pad|>": 248_057,
        ]
        static let offset = 300_000

        func encode(text: String, addSpecialTokens: Bool) -> [Int] {
            var ids: [Int] = []
            var rest = Substring(text)
            while let first = rest.first {
                if let special = Self.specials.first(where: { rest.hasPrefix($0.key) }) {
                    ids.append(special.value)
                    rest = rest.dropFirst(special.key.count)
                } else {
                    ids += first.unicodeScalars.map { Int($0.value) + Self.offset }
                    rest = rest.dropFirst()
                }
            }
            return ids
        }

        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
            let names = Dictionary(uniqueKeysWithValues: Self.specials.map { ($1, $0) })
            return tokenIds.map { (id: Int) -> String in
                if let name = names[id] { return name }
                guard id >= Self.offset, let scalar = Unicode.Scalar(UInt32(id - Self.offset)) else {
                    return "\u{FFFD}"
                }
                return String(Character(scalar))
            }.joined()
        }

        func convertTokenToId(_ token: String) -> Int? { Self.specials[token] }
        func convertIdToToken(_ id: Int) -> String? { nil }
        var bosToken: String? { nil }
        var eosToken: String? { nil }
        var unknownToken: String? { nil }

        func applyChatTemplate(
            messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
            additionalContext: [String: any Sendable]?
        ) throws -> [Int] {
            let image = "<|vision_start|><|image_pad|><|vision_end|>"
            let video = "<|vision_start|><|video_pad|><|vision_end|>"
            return encode(
                text: "user\n" + String(repeating: image, count: images)
                    + String(repeating: video, count: videos) + "What happens?\nassistant\n",
                addSpecialTokens: false)
        }
    }

    /// The Qwen3.8 checkpoint's `preprocessor_config.json`.
    static func configuration() throws -> Qwen3VLProcessorConfiguration {
        let object: [String: Any] = [
            "size": ["longest_edge": 16_777_216, "shortest_edge": 65_536],
            "patch_size": 16, "temporal_patch_size": 2, "merge_size": 2,
            "image_mean": [0.5, 0.5, 0.5], "image_std": [0.5, 0.5, 0.5],
            "image_processor_type": "Qwen2VLImageProcessorFast",
        ]
        return try JSONDecoder().decode(
            Qwen3VLProcessorConfiguration.self,
            from: JSONSerialization.data(withJSONObject: object))
    }

    static func request(images: Int, videos: Int) -> OpenAIChatCompletionRequest {
        OpenAIChatCompletionRequest(
            model: model,
            messages: [
                .init(
                    role: .user,
                    content: .parts(
                        (0 ..< images).map { _ in OpenAIContentPart.imageURL("data:image/png;base64,AA==") }
                            + (0 ..< videos).map { _ in OpenAIContentPart.videoURL("data:video/mp4;base64,AA==") }
                            + [.text("What happens?")]))
            ])
    }

    static func solid(width: Int, height: Int) -> CIImage {
        CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.6))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// `images` full-size pages (1280 x 1024, the processor's own ceiling) and
    /// one 1080p clip of 4 frames at 2 fps: its frames are larger than the
    /// image share, so a share that reached them would shrink them.
    static func input(processing: UserInput.Processing) -> UserInput {
        let page = UserInput.Image.ciImage(solid(width: 1_280, height: 1_024))
        let frame = solid(width: 1_920, height: 1_080)
        let clip = UserInput.Video.frames(
            (0 ..< 4).map {
                UserInput.VideoFrame(image: .ciImage(frame), timeStamp: CMTime(value: Int64($0), timescale: 2))
            })
        var input = UserInput(chat: [
            .user("What happens?", images: Array(repeating: page, count: images), videos: [clip])
        ])
        input.processing = processing
        return input
    }

    static func pixels(_ grid: THW) -> Int { grid.h * 16 * grid.w * 16 }
    static func shape(_ grids: [THW]?) -> [[Int]]? { grids?.map { [$0.t, $0.h, $0.w] } }

    @Test("the image share and the video budget each count their own parts")
    func capsAreIndependent() throws {
        let request = Self.request(images: Self.images, videos: 1)
        #expect(MediaIngest.imagePixelTarget(for: request) == 16 * 1_048_576 / Self.images)
        #expect(
            MediaIngest.videoProcessing(for: request, environment: [:])
                == MediaIngest.videoProcessing(for: Self.request(images: 0, videos: 1), environment: [:]))
        // Clips are no images: 16 images and 4 clips stay within the image budget.
        #expect(MediaIngest.imagePixelTarget(for: Self.request(images: 16, videos: 4)) == nil)
    }

    @Test("the timestamped layout sizes the images to their share and leaves the clip's frames")
    func timestampedClipKeepsItsBudget() async throws {
        let request = Self.request(images: Self.images, videos: 1)
        let share = try #require(MediaIngest.imagePixelTarget(for: request))
        let video = try #require(MediaIngest.videoProcessing(for: request, environment: [:]))
        let processor = Qwen3VLProcessor(
            try Self.configuration(), tokenizer: StubTokenizer(images: Self.images, videos: 1))
        #expect(processor.videoLayout == .timestamped)

        // As `buildUserInput` and `EngineV2VisionPrefill` set them.
        let both = try await processor.prepare(
            input: Self.input(processing: .init(video: video, maxPixels: share)))
        let clipOnly = try await processor.prepare(input: Self.input(processing: .init(video: video)))

        let images = try #require(both.image?.frames)
        let fullImages = try #require(clipOnly.image?.frames)
        #expect(images.count == Self.images)
        #expect(images.allSatisfy { Self.pixels($0) <= share }, "every image within its share")
        #expect(fullImages.allSatisfy { Self.pixels($0) > share }, "the pages exceed the share")

        let clip = try #require(both.video?.frames)
        #expect(Self.shape(clip) == Self.shape(clipOnly.video?.frames), "the share leaves the clip's grid")
        #expect(clip.count == 1 && clip[0].t == 2, "4 frames, 2 pairs")
        #expect(Self.pixels(clip[0]) > share, "frames above the image share")
        let starts = both.text.tokens.asArray(Int32.self).filter { $0 == 248_053 }.count
        #expect(starts == Self.images + 2, "one block per image and per frame pair")
    }

    @Test("the pair's single-block layout keeps its frames under the image share too")
    func pairClipUnchanged() async throws {
        let request = Self.request(images: Self.images, videos: 1)
        let share = try #require(MediaIngest.imagePixelTarget(for: request))
        let pair = Qwen3VLMediaProcessor(try Self.configuration())
            .makeUserInputProcessor(tokenizer: StubTokenizer(images: Self.images, videos: 1))
        #expect(pair.videoLayout == .singleBlock)
        let both = try await pair.prepare(input: Self.input(processing: .init(maxPixels: share)))
        let clipOnly = try await pair.prepare(input: Self.input(processing: .init()))
        let images = try #require(both.image?.frames)
        #expect(images.allSatisfy { Self.pixels($0) <= share })
        let clip = try #require(both.video?.frames)
        #expect(Self.shape(clip) == Self.shape(clipOnly.video?.frames), "the share leaves the clip's grid")
        #expect(clip.allSatisfy { Self.pixels($0) <= Qwen3VLProcessor.maxVideoFramePixels })
        let starts = both.text.tokens.asArray(Int32.self).filter { $0 == 248_053 }.count
        #expect(starts == Self.images + 1, "one block per image and one per clip")
    }

    @Test("the KV reservation covers the shared images and the clip together")
    func reservationCoversBoth() throws {
        let share = try #require(MediaIngest.imagePixelTarget(for: Self.request(images: Self.images, videos: 1)))
        let budget = try #require(MediaIngest.videoBudget(forModel: Self.model, environment: [:]))
        // Each image: its share's tokens and two delimiters; the clip: its
        // budget and, per frame pair, an 8-token label and two delimiters.
        let held = Self.images * (share / 1_024 + 2) + budget.visualTokens + (budget.frames / 2) * 10
        let reserved = MediaIngest.projectedImageTokens(Self.images, model: Self.model)
            + MediaIngest.visionTokensPerVideo
        #expect(reserved >= held)
    }
}
