// Copyright © 2026 Eigen Labs.

import CoreImage
import Foundation
import Jinja
import MLX
import MLXLLM
import MLXLMServer
import MLXVLM
import ProviderCoreFoundation
import Testing

@testable import MLXLMCommon
@testable import ProviderCore

/// Muse Glimmer images on the text route, without weights or a GPU run:
/// the prompt each image renders, the grids upstream's processor picks, the
/// expansion to `<|image_start|>` + patches + `<|image_end|>`, the causal
/// spans the engine splices, and the typed refusals.
@Suite("Muse Glimmer image prefill")
struct MuseGlimmerImagePrefillTests {
    typealias Prefill = MuseGlimmerImagePrefill
    typealias Grid = MuseGlimmerImageGeometry.Grid
    static let modelType = MuseGlimmerModelPolicy.modelType
    static let modelID = MuseGlimmerModelPolicy.catalogModelID
    static var image: [String: Any] { ["type": "image_url", "image_url": ["url": "data:image/png;base64,AAAA"]] }

    static func text(_ value: String) -> [String: Any] { ["type": "text", "text": value] }

    static func body(_ messages: [[String: Any]], extra: [String: Any] = [:]) throws -> Data {
        var body: [String: Any] = ["model": modelID, "messages": messages, "max_tokens": 64]
        body.merge(extra) { $1 }
        return try JSONSerialization.data(withJSONObject: body)
    }

    struct Prepared {
        let request: OpenAIChatCompletionRequest
        let prepared: ToolChoicePromptPolicy.Prepared
        let controls: ChatTemplateControls
    }

    static func prepare(_ body: Data) throws -> Prepared {
        let request = try ProviderLoop.decodeOpenAIRequest(body, modelType: modelType)
        let controls = ProviderLoop.extractChatTemplateControls(from: body).resolvingPromptDate()
        return Prepared(
            request: request, prepared: try ToolChoicePromptPolicy.prepare(request, modelType: modelType),
            controls: controls)
    }

    // MARK: Render, as the runtime tokenizer does (see MuseGlimmerPromptGoldenTests)

    static func fixture(_ name: String, _ fileExtension: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: fileExtension, subdirectory: "Fixtures/MuseGlimmer"))
        return try Data(contentsOf: url)
    }

    static func render(_ input: ProviderPromptContractPipeline.NormalizedInput) throws -> String {
        let template = try #require(String(data: fixture("chat_template", "jinja"), encoding: .utf8))
        let root = try #require(
            JSONSerialization.jsonObject(with: fixture("prompt-golden", "json")) as? [String: Any])
        let reference = try #require(root["reference"] as? [String: Any])
        let specialTokens = try #require(reference["special_tokens"] as? [String: String])
        let compiled = try Template(
            normalizeSwiftJinjaTemplate(template), with: .init(lstripBlocks: true, trimBlocks: true))
        var context: [String: Jinja.Value] = [
            "messages": .array(try input.messages.map { try Jinja.Value(any: $0) }),
            "add_generation_prompt": .boolean(true),
        ]
        if let tools = input.tools { context["tools"] = .array(try tools.map { try Jinja.Value(any: $0) }) }
        var additional = input.additionalContext ?? [:]
        additional.merge(ReferenceTemplateFilters.additionalContext(modelType: modelType) ?? [:]) { _, filter in filter }
        for (key, value) in additional { context[key] = try Jinja.Value(any: value) }
        for (key, value) in specialTokens { context[key] = .string(value) }
        return try compiled.render(context)
    }

    /// The image render, and the text route's render of the same messages with
    /// each image written as a literal `<|patch|>`.
    static func renders(
        _ images: [[String: Any]], _ text: [[String: Any]], extra: [String: Any] = [:]
    ) throws -> (image: String, text: String) {
        let withImages = try prepare(try body(images, extra: extra))
        let asText = try prepare(try body(text, extra: extra))
        return (
            try render(Prefill.templateInput(
                prepared: withImages.prepared, request: withImages.request, modelType: modelType,
                templateControls: withImages.controls)),
            try render(ProviderPromptContractPipeline.templateInput(
                prepared: asText.prepared, request: asText.request, modelType: modelType,
                templateControls: asText.controls)))
    }

    static func occurrences(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    @Test("an image renders as the text render with one <|patch|> in its place")
    func oneImage() throws {
        let rendered = try Self.renders(
            [["role": "user", "content": [Self.text("What is "), Self.image, Self.text(" in this picture?")]]],
            [["role": "user", "content": "What is <|patch|> in this picture?"]])
        #expect(rendered.image == rendered.text)
        #expect(Self.occurrences("<|patch|>", in: rendered.image) == 1)
        #expect(rendered.image.hasSuffix("<|start|>assistant"))
    }

    @Test("several images, a system prompt, history and tools keep the text route's render")
    func conversation() throws {
        let tools: [String: Any] = ["tools": [[
            "type": "function",
            "function": [
                "name": "lookup", "description": "Look a word up.",
                "parameters": ["type": "object", "properties": ["word": ["type": "string"]]],
            ] as [String: Any],
        ]]]
        let rendered = try Self.renders(
            [
                ["role": "system", "content": "Answer briefly."],
                ["role": "user", "content": [Self.image, Self.image, Self.text("Which is larger?")]],
                ["role": "assistant", "content": "The second."],
                ["role": "user", "content": [Self.text("And this one?"), Self.image]],
            ],
            [
                ["role": "system", "content": "Answer briefly."],
                ["role": "user", "content": "<|patch|><|patch|>Which is larger?"],
                ["role": "assistant", "content": "The second."],
                ["role": "user", "content": "And this one?<|patch|>"],
            ],
            extra: tools)
        #expect(rendered.image == rendered.text)
        #expect(Self.occurrences("<|patch|>", in: rendered.image) == 3)
        #expect(rendered.image.contains("lookup"))
    }

    @Test("reasoning controls render as on the text route")
    func reasoningControls() throws {
        let rendered = try Self.renders(
            [["role": "user", "content": [Self.image, Self.text("Count the coins.")]]],
            [["role": "user", "content": "<|patch|>Count the coins."]],
            extra: ["reasoning_effort": "high"])
        #expect(rendered.image == rendered.text)
    }

    @Test("video parts and images outside user messages are refused before any render")
    func refusedParts() throws {
        let video: [String: Any] = ["type": "video_url", "video_url": ["url": "data:video/mp4;base64,AAAA"]]
        // Serving refuses video first (`checkMediaKinds`), before any render.
        let withVideo = try Self.prepare(try Self.body([["role": "user", "content": [Self.text("x"), video]]]))
        #expect(throws: Prefill.refused(Self.modelID, .video)) {
            try Prefill.checkMediaKinds(withVideo.request, modelID: Self.modelID)
        }
        // The render itself also refuses a video part beside an image.
        let mixed = try Self.prepare(try Self.body([["role": "user", "content": [Self.image, Self.text("x"), video]]]))
        #expect(throws: MuseGlimmerImageError.unsupportedMedia("video")) {
            _ = try Prefill.templateInput(
                prepared: mixed.prepared, request: mixed.request, modelType: Self.modelType,
                templateControls: mixed.controls)
        }
        // An image in an assistant message is the caller's fault, before any render.
        let assistant = try Self.prepare(try Self.body([
            ["role": "user", "content": "Show me."],
            ["role": "assistant", "content": [Self.image]],
            ["role": "user", "content": "What was that?"],
        ]))
        #expect(throws: Prefill.nonUserImage) {
            try Prefill.checkPlacement(assistant.request, prepared: assistant.prepared)
        }
        #expect(Prefill.clientFault(for: MuseGlimmerImageError.unsupportedMedia("video"), modelID: Self.modelID)
            == Prefill.refused(Self.modelID, .video))
    }

    @Test("a forced tool choice with images is refused; auto and none are served")
    func forcedToolChoice() throws {
        let tools: [[String: Any]] = [[
            "type": "function",
            "function": ["name": "lookup", "parameters": ["type": "object", "properties": [:] as [String: Any]]]
                as [String: Any],
        ]]
        let messages: [[String: Any]] = [["role": "user", "content": [Self.image, Self.text("Look it up.")]]]
        for choice in ["auto", "none"] {
            let request = try Self.prepare(try Self.body(messages, extra: ["tools": tools, "tool_choice": choice]))
            try Prefill.checkPlacement(request.request, prepared: request.prepared)
        }
        let required = try Self.prepare(try Self.body(messages, extra: ["tools": tools, "tool_choice": "required"]))
        #expect(throws: MultiModelBatchSchedulerEngineError.invalidToolPayload(
            "inference-enforced tool_choice is not supported for multimodal requests",
            refusal: .unsupportedForcedToolChoice)) {
            try Prefill.checkPlacement(required.request, prepared: required.prepared)
        }
    }

    @Test("a slot whose artifact fails an integrity check refuses with its reason, as a 400")
    func slotRefusals() throws {
        let request = try Self.prepare(try Self.body([["role": "user", "content": [Self.image, Self.text("Hi")]]]))
        let cases: [(MuseGlimmerImageService?, MuseGlimmerVisionPolicy.Refusal)] = [
            (nil, .encoderUnavailable),
            (.refused(.configuration), .configuration),
            (.refused(.unpinnedArtifact(file: "processor_config.json")),
             .unpinnedArtifact(file: "processor_config.json")),
        ]
        for (service, refusal) in cases {
            let expected = MultiModelBatchSchedulerEngineError.mediaUnsupportedByModel(
                Self.modelID, reason: refusal.reason)
            #expect(throws: expected) {
                _ = try Prefill.servingEncoder(
                    service: service, request: request.request, prepared: request.prepared, modelID: Self.modelID)
            }
            #expect(expected.errorDescription?.hasSuffix(": " + refusal.reason) == true)
            #expect(ProviderLoop.mapInferenceErrorToStatus(expected) == 400)
            // On the wire: the closed code and its fixed message, never the reason text.
            let failure = ProviderLoop.sanitizedInferenceFailure(from: expected, phase: .streamStart)
            #expect(failure.code == .unsupportedMedia)
            #expect(failure.statusCode == 400)
            #expect(failure.message == "Media input is not supported.")
            let wire = try ProviderProtocolCodec.encodeProviderMessage(.inferenceError(
                ProviderMessage.InferenceError(requestId: "request-id", failure: failure)))
            let wireText = try #require(String(data: wire, encoding: .utf8))
            #expect(wireText.contains(#""failure_code":"unsupported_media""#))
            #expect(!wireText.contains(refusal.reason))
        }
        // Without a reason the message is the generic one, unchanged.
        #expect(MultiModelBatchSchedulerEngineError.mediaUnsupportedByModel("m").errorDescription
            == "Model 'm' does not support image or video input on this provider")
    }

    // MARK: Grids (notes/reference-spec A2.1, upstream's processor)

    static func ciImage(height: CGFloat, width: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    @Test("grids: upstream's smart_resize at 28 px and at most 4,096 merged tokens")
    func gridGoldens() throws {
        // height, width -> merged rows x columns, measured from the reference processor.
        let goldens: [(Int, Int, Int, Int)] = [
            (224, 224, 8, 8), (448, 448, 16, 16), (768, 1024, 27, 36), (1080, 1920, 39, 69),
            (1792, 1792, 64, 64), (2160, 3840, 48, 85), (3000, 4000, 55, 73), (100, 4000, 4, 143),
            (13, 13, 1, 1),
        ]
        let grids = try Prefill.grids(for: goldens.map { Self.ciImage(height: CGFloat($0.0), width: CGFloat($0.1)) })
        for (golden, grid) in zip(goldens, grids) {
            let expected = try Grid(mergedRows: golden.2, mergedColumns: golden.3)
            #expect(grid == expected, "\(golden.0)x\(golden.1)")
            #expect(grid.promptTokens == golden.2 * golden.3 + 2)
            #expect(grid.promptTokens <= MuseGlimmerVisionPolicy.maximumPromptTokensPerImage)
        }
        #expect(grids.map(\.featureRows) == [64, 256, 972, 2_691, 4_096, 4_080, 4_015, 572, 1])
        // A fractional extent rounds as the SDK's preprocessing rounds it.
        #expect(try Prefill.grids(for: [Self.ciImage(height: 447.6, width: 448.4)])
            == Prefill.grids(for: [Self.ciImage(height: 448, width: 448)]))
    }

    // MARK: Expansion and spans

    static func features(_ grid: Grid) -> MLXArray {
        MLXArray([Float](repeating: 0, count: grid.featureRows * 2), [grid.featureRows, 2])
    }

    @Test("expansion: each placeholder becomes start, its patches and end; spans cover the patches")
    func expansion() throws {
        let grids = [try Grid(mergedRows: 16, mergedColumns: 16), try Grid(mergedRows: 39, mergedColumns: 69)]
        let images = grids.map { Self.ciImage(height: CGFloat($0.pixelHeight), width: CGFloat($0.pixelWidth)) }
        var encoded: [Grid] = []
        var checkpoints = 0
        let prepared = try Prefill.submission(
            promptTokens: [7, 200_092, 8, 200_092, 9], images: images, grids: grids,
            features: { _, grid in encoded.append(grid); return Self.features(grid) },
            checkpoint: { checkpoints += 1 })
        let submission = prepared.submission
        #expect(encoded == grids)
        #expect(checkpoints == 3)
        #expect(submission.promptTokens.count == 3 + 258 + 2_693)
        #expect(submission.promptTokens.prefix(3) == [7, 200_080, 200_092])
        #expect(submission.promptTokens[257] == 200_092)
        #expect(submission.promptTokens[258] == 200_081)
        #expect(Array(submission.promptTokens[259 ... 261]) == [8, 200_080, 200_092])
        #expect(submission.promptTokens.suffix(2) == [200_081, 9])
        #expect(submission.promptTokens.filter { $0 == 200_092 }.count == 256 + 2_691)
        #expect(submission.spans.map(\.tokenOffset) == [2, 261])
        #expect(submission.spans.map(\.length) == [256, 2_691])
        #expect(submission.attention == .causal)
        #expect(submission.positionState == nil)
        #expect(submission.mediaKind == .image)
        let input = submission.multimodalInput()
        #expect(input.attention == .causal)
        #expect(input.spans == submission.spans)
        #expect(try input.embeddings().map(\.shape) == [[256, 2], [2_691, 2]])
    }

    @Test("causal image spans leave the 1,024-token prefill grid in place")
    func prefillGrid() throws {
        let grid = try Grid(mergedRows: 64, mergedColumns: 64)
        let prompt = [1] + [200_092] + Array(repeating: 5, count: 700)
        let prepared = try Prefill.submission(
            promptTokens: prompt, images: [Self.ciImage(height: 1_792, width: 1_792)], grids: [grid],
            features: { _, grid in Self.features(grid) }, checkpoint: {})
        let tokens = prepared.submission.promptTokens
        #expect(tokens.count == 4_799)
        let record = CBv2ScheduledRequest(
            request: CBv2Request(
                id: CBv2RequestID(1), promptTokens: tokens, maxTokens: 16,
                multimodal: prepared.submission.multimodalInput()),
            arrivalSeq: 0, submittedAt: Date())
        // No bidirectional blocks: the span may cross a chunk boundary.
        #expect(record.multimodalBlocks.isEmpty)
        let span = prepared.submission.spans[0]
        #expect(span.tokenOffset < 1_024 && span.tokenOffset + span.length > 1_024)
        // The model's own grid (`prefillChunkAlignment`), unchanged by the image.
        let alignment = MuseGlimmerTextModel.defaultPrefillChunkAlignment
        #expect(alignment == 1_024)
        var start = 0
        var cells: [Int] = []
        while start < tokens.count {
            let cell = try #require(SchedulerV2.prefillGridCell(
                alignment: alignment, start: start, promptTokens: tokens.count, end: tokens.count,
                plan: nil, hasBlocks: !record.multimodalBlocks.isEmpty))
            cells.append(cell)
            start += cell
        }
        #expect(cells == [1_024, 1_024, 1_024, 1_024, 703])
    }

    @Test("placeholders and images must agree before any image is encoded")
    func placeholderMismatch() throws {
        let grid = try Grid(mergedRows: 16, mergedColumns: 16)
        let image = Self.ciImage(height: 448, width: 448)
        var encoded = 0
        let encode: (CIImage, Grid) throws -> MLXArray = { _, grid in encoded += 1; return Self.features(grid) }
        // A literal <|patch|> in the user's text is one placeholder too many.
        #expect(throws: MuseGlimmerImageError.self) {
            _ = try Prefill.submission(
                promptTokens: [200_092, 200_092], images: [image], grids: [grid], features: encode, checkpoint: {})
        }
        #expect(throws: MuseGlimmerImageError.self) {
            _ = try Prefill.submission(
                promptTokens: [1, 2], images: [image], grids: [grid], features: encode, checkpoint: {})
        }
        #expect(throws: MuseGlimmerImageError.unsupportedMedia("video placeholder")) {
            _ = try Prefill.submission(
                promptTokens: [200_092, 200_091], images: [image], grids: [grid], features: encode, checkpoint: {})
        }
        #expect(throws: MuseGlimmerImageError.placeholders("grids")) {
            _ = try Prefill.submission(
                promptTokens: [200_092], images: [image, image], grids: [grid], features: encode, checkpoint: {})
        }
        #expect(encoded == 0)
    }

    @Test("a deadline or cancellation between images stops the tower")
    func checkpointStops() throws {
        struct Expired: Error {}
        let grid = try Grid(mergedRows: 16, mergedColumns: 16)
        let image = Self.ciImage(height: 448, width: 448)
        var encoded = 0
        var checkpoints = 0
        #expect(throws: Expired.self) {
            _ = try Prefill.submission(
                promptTokens: [200_092, 200_092, 200_092], images: [image, image, image], grids: [grid, grid, grid],
                features: { _, grid in encoded += 1; return Self.features(grid) },
                checkpoint: { checkpoints += 1; if checkpoints == 2 { throw Expired() } })
        }
        #expect(encoded == 1)
    }

    @Test("the request's own image faults are fixed-text 400s; artifact faults are not the request's")
    func clientFaults() {
        let geometry = Prefill.clientFault(for: MuseGlimmerImageError.geometry("source 0x9"), modelID: Self.modelID)
        let placeholders = Prefill.clientFault(
            for: MuseGlimmerImageError.placeholders("2 image placeholders for 1 images"), modelID: Self.modelID)
        for fault in [geometry, placeholders] {
            guard case .multimodalRejected(let message)? = fault else {
                Issue.record("not a multimodal rejection: \(String(describing: fault))")
                continue
            }
            #expect(message.hasPrefix("multimodal_rejected: "))
            let namesNumbers = message.contains { $0.isNumber }
            #expect(!namesNumbers, "\(message)")
            #expect(ProviderLoop.mapInferenceErrorToStatus(fault!) == 400)
        }
        for artifact in [MuseGlimmerImageError.identity("x"), .missing("x"), .unexpected("x"), .layout("x"), .dtype("x")] {
            #expect(Prefill.clientFault(for: artifact, modelID: Self.modelID) == nil)
        }
        #expect(Prefill.clientFault(for: CancellationError(), modelID: Self.modelID) == nil)
    }
}
