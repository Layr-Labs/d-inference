// Copyright © 2026 Eigen Labs.
import CryptoKit
import Foundation
import Jinja
import MLXLMCommon
import MLXVLM
import ProviderCoreFoundation
import Testing
@testable import ProviderCore

/// Committed reference clips and goldens computed with NVIDIA's serving path:
/// vLLM's OpenCV loader at 2 fps and 256 frames, and the HF processor
/// `processing_nemotron_h_omni.py` with the pinned tokenizer (whose ids equal
/// vLLM's `get_video_repl`). Read through the source tree so the isolated
/// harness needs no resource bundle.
enum NemotronSuperVideoFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/NemotronSuperVideos", isDirectory: true)

    static func data(_ file: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(file))
    }

    static func uri(_ file: String) throws -> String {
        "data:video/mp4;base64," + (try data(file)).base64EncodedString()
    }

    struct Golden: Decodable {
        struct Grid: Decodable {
            let widthPatches: Int
            let heightPatches: Int
            let width: Int
            let height: Int
            let tokens: Int
        }
        /// A token, or `[token, count]` for a run.
        struct Run: Decodable {
            let token: Int
            let count: Int
            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let token = try? container.decode(Int.self) {
                    self.token = token
                    count = 1
                } else {
                    let pair = try container.decode([Int].self)
                    guard pair.count == 2 else {
                        throw DecodingError.dataCorruptedError(in: container, debugDescription: "run")
                    }
                    token = pair[0]
                    count = pair[1]
                }
            }
        }
        struct Clip: Decodable {
            let file: String
            let sha256: String
            let totalFrames: Int
            let srcFps: Double
            let sampledIndices: [Int]
            let timestamps: [String]
            let grid: Grid
            let tubeletLabels: [String]
            let labelTokenIds: [[Int]]
            let replacementTokenRuns: [Run]
            let retainedRows: [String: Int]

            var replacementTokens: [Int] { replacementTokenRuns.flatMap { Array(repeating: $0.token, count: $0.count) } }
        }
        struct Render: Decodable {
            let name: String
            let enableThinking: Bool
            /// `video_url` parts carry no URL here.
            let content: [[String: String]]
            let templateText: String
            let prefixTokenIds: [Int]
            let suffixTokenIds: [Int]
            let totalPromptTokens: Int
        }
        struct ChatTemplate: Decodable {
            let clip: String
            let renders: [Render]
        }
        let clips: [Clip]
        let chatTemplate: ChatTemplate
    }

    static func golden() throws -> Golden {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Golden.self, from: data("nemotron-super-video-golden.json"))
    }

    /// The render's request body, its video under `uri`.
    static func body(_ render: Golden.Render, uri: String = "data:video/mp4;base64,AAAA") throws -> Data {
        let content: [[String: Any]] = render.content.map { part -> [String: Any] in
            guard part["type"] == "video_url" else { return part }
            return ["type": "video_url", "video_url": ["url": uri]]
        }
        return try JSONSerialization.data(withJSONObject: [
            "model": NemotronSuperLocalBinding.modelID, "enable_thinking": render.enableThinking,
            "messages": [["role": "user", "content": content]],
        ] as [String: Any])
    }
}

struct NemotronSuperVideoGoldenTests {
    private static func template() throws -> Data {
        try #require(Data(base64Encoded: superImagePinnedTemplateBase64, options: .ignoreUnknownCharacters))
    }

    @Test func clipsAreTheReferenceBytes() throws {
        let golden = try NemotronSuperVideoFixtures.golden()
        #expect(golden.clips.count == 3)
        for clip in golden.clips {
            let digest = SHA256.hash(data: try NemotronSuperVideoFixtures.data(clip.file))
                .map { String(format: "%02x", $0) }.joined()
            #expect(digest == clip.sha256, "\(clip.file)")
        }
    }

    /// Frame count and rate from the compressed samples, the sampled
    /// indices, labels and frame grid all equal the reference loader's.
    @Test func inspectionReproducesTheReferenceSampling() async throws {
        for clip in try NemotronSuperVideoFixtures.golden().clips {
            let plan = try await NemotronSuperVideoDecode.inspect(try NemotronSuperVideoFixtures.uri(clip.file))
            #expect(plan.sourceFrames == clip.totalFrames, "\(clip.file)")
            #expect(plan.sourceFPS == clip.srcFps, "\(clip.file)")
            #expect(plan.frameIndices == clip.sampledIndices, "\(clip.file)")
            #expect(plan.labels == clip.tubeletLabels, "\(clip.file)")
            #expect(plan.tubelets == clip.labelTokenIds.count, "\(clip.file)")
            #expect(plan.grid.widthPatches == clip.grid.widthPatches && plan.grid.heightPatches == clip.grid.heightPatches
                && plan.grid.width == clip.grid.width && plan.grid.height == clip.grid.height
                && plan.grid.tokens == clip.grid.tokens, "\(clip.file)")
        }
    }

    /// Every sampled frame decodes at the grid; an odd count repeats its last
    /// frame once to complete the final tubelet.
    @Test func framesDecodeAtTheGridAndCompleteAnOddTubelet() async throws {
        for clip in try NemotronSuperVideoFixtures.golden().clips {
            let plan = try await NemotronSuperVideoDecode.inspect(try NemotronSuperVideoFixtures.uri(clip.file))
            let frames = try await NemotronSuperVideoDecode.Frames(plan)
            var decoded: [[Float]] = []
            while let frame = try frames.next() { decoded.append(frame) }
            #expect(decoded.count == 2 * plan.tubelets, "\(clip.file)")
            #expect(decoded.allSatisfy { $0.count == 3 * plan.grid.width * plan.grid.height }, "\(clip.file)")
            #expect(decoded.allSatisfy { $0.allSatisfy(\.isFinite) }, "\(clip.file)")
            if clip.sampledIndices.count % 2 == 1 {
                #expect(decoded[decoded.count - 1] == decoded[decoded.count - 2], "\(clip.file)")
            }
            #expect(try frames.next() == nil)
        }
    }

    /// The colors clip's first two seconds are red behind a white caption, so
    /// its decoded frame 0, with CLIP normalization undone, is red-dominant:
    /// the frame really is the clip's content in RGB order.
    @Test func firstColorsFrameDecodesRed() async throws {
        let plan = try await NemotronSuperVideoDecode.inspect(try NemotronSuperVideoFixtures.uri("colors_16x9.mp4"))
        #expect(plan.frameIndices.first == 0)
        let frames = try await NemotronSuperVideoDecode.Frames(plan)
        let frame = try #require(try frames.next())
        let plane = plan.grid.width * plan.grid.height
        try #require(frame.count == 3 * plane)
        let mean: [Double] = [0.48145466, 0.4578275, 0.40821073]
        let std: [Double] = [0.26862954, 0.26130258, 0.27577711]
        let channels = (0 ..< 3).map { channel -> Double in
            let normalized = frame[(channel * plane) ..< ((channel + 1) * plane)].reduce(0.0) { $0 + Double($1) }
            return normalized / Double(plane) * std[channel] + mean[channel]
        }
        #expect(channels[0] > 0.75 && channels[1] < 0.25 && channels[2] < 0.25, "\(channels)")
        #expect(channels[0] > channels[1] + 0.5 && channels[0] > channels[2] + 0.5, "\(channels)")
    }

    @Test func retainedRowsFollowEVS() throws {
        for clip in try NemotronSuperVideoFixtures.golden().clips {
            for (rate, rows) in clip.retainedRows {
                let pruningRate = try #require(Double(rate))
                #expect(NemotronSuperVideoFeatures.retainedRows(tubelets: clip.labelTokenIds.count,
                    rowsPerTubelet: clip.grid.tokens, pruningRate: pruningRate) == rows, "\(clip.file) q=\(rate)")
            }
        }
    }

    /// The tubelet layout from the reference label ids reproduces the
    /// processor's `<video>` replacement ids exactly.
    @Test func replacementLayoutReproducesTheReferenceIDs() throws {
        for clip in try NemotronSuperVideoFixtures.golden().clips {
            let prompt = NemotronSuperPromptContract.VideoPrompt(prefix: [], labels: clip.labelTokenIds, suffix: [])
            let kept = Array(repeating: clip.grid.tokens, count: clip.labelTokenIds.count)
            #expect(try prompt.tokens(keptCounts: kept, contextLength: 16_384) == clip.replacementTokens, "\(clip.file)")
        }
    }

    /// The pinned template with the video in an image's slot gives the
    /// reference text once the slot is expanded, for video before and after
    /// text and both thinking modes.
    @Test func videoSlotReproducesTheReferenceTemplateText() throws {
        let golden = try NemotronSuperVideoFixtures.golden()
        let clip = try #require(golden.clips.first { $0.file == golden.chatTemplate.clip })
        let kept = Array(repeating: clip.grid.tokens, count: clip.tubeletLabels.count)
        let replacement = clip.tubeletLabels.enumerated().map { index, label in
            (index == 0 ? "" : "\n") + label + "<img>" + String(repeating: "<image>", count: kept[index]) + "</img>"
        }.joined()
        for render in golden.chatTemplate.renders {
            let body = try NemotronSuperVideoFixtures.body(render)
            let prompt = try NemotronSuperPromptContract.videoPrompt(
                messages: ProviderLoop.decodeOpenAIRequest(body).messages, body: body,
                templateBytes: Self.template(), tokenizer: SuperVideoTextTokenizer(), labels: clip.tubeletLabels)
            let text = SuperVideoTextTokenizer.text(try prompt.tokens(keptCounts: kept, contextLength: 16_384))
            #expect(text == render.templateText.replacingOccurrences(of: "<video>", with: replacement), "\(render.name)")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEMOTRON_SUPER_REFERENCE_DIR"] != nil))
    func realTokenizerReproducesTheReferencePromptIDs() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["NEMOTRON_SUPER_REFERENCE_DIR"])
        let tokenizer = try await LocalTokenizerLoader().load(from: URL(fileURLWithPath: path, isDirectory: true))
        let golden = try NemotronSuperVideoFixtures.golden()
        let render = try #require(golden.chatTemplate.renders.first)
        for clip in golden.clips {
            let body = try NemotronSuperVideoFixtures.body(render)
            let prompt = try NemotronSuperPromptContract.videoPrompt(
                messages: ProviderLoop.decodeOpenAIRequest(body).messages, body: body,
                templateBytes: Self.template(), tokenizer: tokenizer, labels: clip.tubeletLabels)
            #expect(prompt.labels == clip.labelTokenIds, "\(clip.file)")
        }
        let clip = try #require(golden.clips.first { $0.file == golden.chatTemplate.clip })
        let kept = Array(repeating: clip.grid.tokens, count: clip.tubeletLabels.count)
        for render in golden.chatTemplate.renders {
            let body = try NemotronSuperVideoFixtures.body(render)
            let prompt = try NemotronSuperPromptContract.videoPrompt(
                messages: ProviderLoop.decodeOpenAIRequest(body).messages, body: body,
                templateBytes: Self.template(), tokenizer: tokenizer, labels: clip.tubeletLabels)
            let tokens = try prompt.tokens(keptCounts: kept, contextLength: 16_384)
            #expect(tokens == render.prefixTokenIds + clip.replacementTokens + render.suffixTokenIds, "\(render.name)")
            #expect(tokens.count == render.totalPromptTokens, "\(render.name)")
        }
    }
}

/// Renders with swift-jinja as swift-transformers' `applyChatTemplate` does
/// and encodes text as Unicode scalars, with `<image>`, `<img>` and `</img>`
/// as their special ids. Not a tokenizer; never used for execution.
struct SuperVideoTextTokenizer: MLXLMCommon.Tokenizer {
    private static let specials = [("<image>", 18), ("<img>", 19), ("</img>", 20)]

    static func text(_ tokens: [Int]) -> String {
        tokens.map { token in
            specials.first { $0.1 == token }?.0 ?? String(Character(Unicode.Scalar(UInt32(token)) ?? "?"))
        }.joined()
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        var tokens: [Int] = []
        var rest = text[...]
        while let scalar = rest.unicodeScalars.first {
            if let special = Self.specials.first(where: { rest.hasPrefix($0.0) }) {
                tokens.append(special.1)
                rest = rest.dropFirst(special.0.count)
            } else {
                tokens.append(Int(scalar.value))
                rest = Substring(rest.unicodeScalars.dropFirst())
            }
        }
        return tokens
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { Self.text(tokenIds) }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { "<s>" }
    var eosToken: String? { "<|im_end|>" }
    var unknownToken: String? { "<unk>" }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        throw MLXLMCommon.TokenizerError.missingChatTemplate
    }
    func applyChatTemplate(messages: [[String: any Sendable]], chatTemplate: String) throws -> [Int] {
        try applyChatTemplate(messages: messages, chatTemplate: chatTemplate, tools: nil, additionalContext: nil)
    }
    func applyChatTemplate(messages: [[String: any Sendable]], chatTemplate: String,
                           tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
        let template = try Template(normalizeSwiftJinjaTemplate(chatTemplate),
                                    with: .init(lstripBlocks: true, trimBlocks: true))
        var context: [String: Value] = ["messages": .array(try messages.map { try Value(any: $0) }),
                                        "add_generation_prompt": true]
        if let tools { context["tools"] = .array(try tools.map { try Value(any: $0) }) }
        for (key, value) in additionalContext ?? [:] { context[key] = try Value(any: value) }
        for (key, value) in ["bos_token": "<s>", "eos_token": "<|im_end|>", "unk_token": "<unk>",
                             "pad_token": "<|im_end|>"] { context[key] = .string(value) }
        return encode(text: try template.render(context), addSpecialTokens: false)
    }
}
