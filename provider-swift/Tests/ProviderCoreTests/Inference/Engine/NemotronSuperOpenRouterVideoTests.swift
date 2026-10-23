// Copyright © 2026 Eigen Labs.
import CryptoKit
import Foundation
import MLXLMCommon
import Testing
@testable import MLXVLM
@testable import ProviderCore

/// OpenRouter's provider-readiness videos through the Super binding without
/// the checkpoint: ingress, request parsing, inspection, the pinned template's
/// prompt, the media plan and every sampled frame's decode, then served on the
/// tiny installed fixture. The clips are the SDK's committed `MiMoOpenRouter`
/// test resources, read through the source tree. `input-video-url` reaches the
/// provider as the coordinator inlines a fetched link; `input-video-base64`
/// arrives inline.
struct NemotronSuperOpenRouterVideoTests {
    private typealias Binding = NemotronSuperLocalImageBinding
    private typealias Policy = NemotronSuperServingPolicy

    private static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("libs/mlx-swift-lm/Tests/MLXLMTests/Resources/MiMoOpenRouter", isDirectory: true)

    private struct Clip {
        let file: String
        let label: String
        let sha256: String
        let sourceFrames: Int
        let frameIndices: [Int]
        let codedWidth: Int
        let codedHeight: Int
        let widthPatches: Int
        let heightPatches: Int
    }

    /// H.264 1280 x 720 at a constant 24 fps (121 frames, an edit list and an
    /// AAC track), and H.264 1490 x 534 QuickTime at a variable rate (211
    /// frames over 10.83 s). Two frames a second, spread as `np.linspace`.
    private static let clips = [
        Clip(file: "input-video-url.mp4", label: "data:video/mp4;base64,",
             sha256: "dc11648bd3546cd0a37ecc1077ccc426d42c409fe4822ece0354eb250804431e", sourceFrames: 121,
             frameIndices: [0, 13, 26, 40, 53, 66, 80, 93, 106, 120], codedWidth: 1_280, codedHeight: 720,
             widthPatches: 42, heightPatches: 24),
        Clip(file: "input-video-base64.mov", label: "data:video/quicktime;base64,",
             sha256: "0a53a3aa1da409c54b57b6955139525f77c421893aaa172ebc1f86ba3a7323f4", sourceFrames: 211,
             frameIndices: [0, 10, 21, 31, 42, 52, 63, 73, 84, 94, 105, 115, 126, 136, 147, 157, 168, 178, 189,
                            199, 210],
             codedWidth: 1_490, codedHeight: 534, widthPatches: 52, heightPatches: 18),
    ]

    private static func uri(_ clip: Clip) throws -> String {
        let data = try Data(contentsOf: directory.appendingPathComponent(clip.file))
        try #require(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == clip.sha256, "\(clip.file)")
        return clip.label + data.base64EncodedString()
    }

    private static func body(_ uri: String, model: String = Policy.modelID, maxTokens: Int = 256) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model": model, "stream": true, "max_tokens": maxTokens, "temperature": 0,
            "messages": [["role": "user", "content": [
                ["type": "text", "text": "Describe what happens in this video."],
                ["type": "video_url", "video_url": ["url": uri]],
            ]]],
        ] as [String: Any])
    }

    private static func template() throws -> Data {
        try #require(Data(base64Encoded: superImagePinnedTemplateBase64, options: .ignoreUnknownCharacters))
    }

    /// The inlined 6.9 MB link is a 9.3 MB body, above the former 8 MiB
    /// ingress bound that refused it as invalid media.
    @Test func inlinedLinkVideoPassesIngress() throws {
        let clip = try #require(Self.clips.first)
        let body = try Self.body(try Self.uri(clip))
        #expect(body.count > 8 << 20)
        let ingress = try Binding.encodedHeaderQuote(bodyBytes: body.count, templateBytes: Policy.pinnedTemplateBytes)
        #expect(ingress == UInt64(body.count) * 32 + UInt64(Policy.pinnedTemplateBytes) * 4 + (16 << 20))
        let parsed = try Binding.parseEncodedBody(body, modelID: Policy.modelID)
        #expect(parsed.images.isEmpty && parsed.video?.hasPrefix(clip.label) == true)
    }

    /// Each clip plans at its reference sampling and grid, renders in the
    /// pinned template's media slot, reserves within the policy's video bound
    /// and decodes every sampled frame at the grid.
    @Test(.timeLimit(.minutes(3))) func bothClipsPlanAndDecodeAtTheirGrid() async throws {
        for clip in Self.clips {
            let uri = try Self.uri(clip)
            let body = try Self.body(uri)
            let parsed = try Binding.parseEncodedBody(body, modelID: Policy.modelID)
            let video = try await NemotronSuperVideoDecode.inspect(try #require(parsed.video))
            #expect(video.sourceFrames == clip.sourceFrames, "\(clip.file)")
            #expect(video.frameIndices == clip.frameIndices, "\(clip.file)")
            #expect(video.codedWidth == clip.codedWidth && video.codedHeight == clip.codedHeight, "\(clip.file)")
            #expect(video.width == clip.codedWidth && video.height == clip.codedHeight, "\(clip.file)")
            #expect(video.grid.widthPatches == clip.widthPatches && video.grid.heightPatches == clip.heightPatches,
                    "\(clip.file)")
            #expect(video.tubelets == (clip.frameIndices.count + 1) / 2, "\(clip.file)")
            #expect(video.labels.count == video.tubelets, "\(clip.file)")

            let prompt = try NemotronSuperPromptContract.videoPrompt(
                messages: ProviderLoop.decodeOpenAIRequest(body).messages, body: body,
                templateBytes: Self.template(), tokenizer: SuperVideoTextTokenizer(), labels: video.labels)
            let plan = try Binding.encodedVideoPlan(video, prompt: prompt,
                pruningRate: NemotronSuperVideoPreprocessing.defaultPruningRate, contextLength: Policy.contextTokens)
            let rows = NemotronSuperVideoFeatures.retainedRows(tubelets: video.tubelets,
                rowsPerTubelet: video.grid.tokens, pruningRate: NemotronSuperVideoPreprocessing.defaultPruningRate)
            #expect(plan.featureBytes == rows * 4096 * 4, "\(clip.file)")
            let ingress = try Binding.encodedHeaderQuote(bodyBytes: body.count,
                                                         templateBytes: Policy.pinnedTemplateBytes)
            #expect(ingress + plan.totalBytes <= (Policy.videoMediaChargeBytes ?? 0), "\(clip.file)")

            let frames = try await NemotronSuperVideoDecode.Frames(video)
            let decoded = try await frames.withCancellableReader { () throws -> [[Float]] in
                var decoded: [[Float]] = []
                while let frame = try frames.next() { decoded.append(frame) }
                return decoded
            }
            #expect(decoded.count == 2 * video.tubelets, "\(clip.file)")
            #expect(decoded.allSatisfy { $0.count == 3 * video.grid.width * video.grid.height }, "\(clip.file)")
            #expect(decoded.allSatisfy { $0.allSatisfy(\.isFinite) }, "\(clip.file)")
        }
    }

    /// Both request bodies served by the owner's encoded entry point on the
    /// tiny installed fixture: ingress, inspection, every frame, the tower,
    /// EVS and generation, with every charge returned.
    @Test(.timeLimit(.minutes(3))) func bothClipsServeOnTheInstalledFixture() async throws {
        let (installed, construction, residency) = try SuperInstalledFixture(radioDimensions: NemotronRadioDimensions(
            width: 2, layers: 1, heads: 1, channels: 3, patch: 16, positionSide: 32, prefix: 1, mlpWidth: 3)).make()
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 16 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-openrouter-video",
            weightBytes: UInt64(installed.receipt.payloadBytes), minimumKVBytes: 2 << 30))
        let owner = try await NemotronSuperLocalBridgeBuilder.make(installed: installed,
            tokenizer: TokenizerHandle(SuperSyntheticVideoTokenizer()), eosTokenIDs: [31],
            sizing: .init(weightsBytes: installed.receipt.payloadBytes, fp16KVBytesPerToken: 64,
                maxContextLength: 4_096, defaultMaxTokens: 2), kvBytesCapacity: 2 << 30,
            kvBudget: budget, loadLease: lease, construction: construction, environment: [:])
        let media = try owner.localImageBinding()
        let template = try Self.template()
        let baseline = await budget.outstandingReservedBytes()
        for clip in Self.clips {
            let body = try Self.body(try Self.uri(clip), model: owner.modelID, maxTokens: 2)
            let events = OpenRouterVideoEvents()
            try await media.runEncoded(body: body, templateBytes: template) { await events.record($0) }
            #expect(await events.errors.isEmpty, "\(clip.file)")
            #expect(await events.completions == [2], "\(clip.file)")
            #expect(await budget.outstandingReservedBytes() == baseline, "\(clip.file)")
        }
        try await owner.closeAfterDrain()
        #expect(residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }
}

private actor OpenRouterVideoEvents {
    var errors: [String] = []
    var completions: [Int] = []
    func record(_ event: GenerationEvent) {
        switch event {
        case .chunk: break
        case .info(_, let count, _, _): completions.append(count)
        case .error(let message): errors.append(message)
        case .terminal(_, let message, _, _): errors.append(message)
        }
    }
}
