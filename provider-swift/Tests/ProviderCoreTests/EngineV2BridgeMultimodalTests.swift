// Copyright © 2026 Eigen Labs.

import MLX
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore
// MARK: - Bridge multimodal passthrough

@Suite("EngineV2Bridge multimodal submit")
struct EngineV2BridgeMultimodalTests {

    init() {
        // MLXArray comparisons below force evaluation — the metallib must be
        // colocated with the test runner (CI copies it into the bundle; the
        // fixture self-heals locally from .build/debug).
        _ = visionEnsureMetallibColocated()
    }

    @Test("multimodal input rides CBv2Request verbatim; INFO telemetry tagged multimodal")
    func multimodalPassthrough() async throws {
        let engine = VisionScriptedEngine(
            script: .stream([
                .delta(text: "Red", tokens: [10], logprobs: nil),
                .finished(reason: .stop, usage: CBv2Usage(promptTokens: 6, completionTokens: 1)),
            ]))
        let telemetry = VisionTelemetrySink()
        let bridge = visionMakeBridge(engine: engine, telemetry: telemetry)
        let (prepared, embedding) = visionMakePreparedSubmission()

        let request = ChatCompletionRequest(
            model: "test/vlm-stub",
            messages: [ChatMessage(role: "user", content: "hi")],
            temperature: 0, max_tokens: 8)
        let stream = await bridge.submitTokenized(
            promptTokens: prepared.promptTokens,
            request: request,
            requestId: "req-vision-1",
            multimodal: prepared.multimodalInput(),
            mediaKind: .video
        )
        var text = ""
        for await event in stream {
            if case .chunk(let chunk) = event { text += chunk }
        }
        #expect(text == "Red")

        let submitted = try #require(engine.submitted.first)
        #expect(submitted.promptTokens == prepared.promptTokens)
        let multimodal = try #require(submitted.multimodal)
        #expect(multimodal.spans == prepared.spans)
        let arrays = try multimodal.embeddings()
        #expect(arrays.count == 1)
        #expect(arrays[0].shape == embedding.shape)
        #expect(arrays[0].asArray(Float.self) == embedding.asArray(Float.self))

        // Engagement telemetry: INFO, engine_v2_vision, multimodal=true,
        // media_kind riding the caller-supplied tag.
        let visionEvents = telemetry.events.filter {
            $0.fields?["operation"]?.description == "engine_v2_vision"
        }
        #expect(visionEvents.count == 1)
        #expect(visionEvents.first?.fields?["multimodal"]?.description == "true")
        #expect(visionEvents.first?.fields?["media_kind"]?.description == "video")
        #expect(visionEvents.first?.fields?["backend"]?.description == "engine_v2")
        #expect(visionEvents.first?.requestId == "req-vision-1")
    }

    @Test("Qwen position state rides the multimodal input into CBv2Request")
    func qwenPositionStatePassthrough() async throws {
        let engine = VisionScriptedEngine(
            script: .stream([
                .finished(
                    reason: .stop,
                    usage: CBv2Usage(promptTokens: 3, completionTokens: 0))
            ]))
        let bridge = visionMakeBridge(engine: engine)
        let positions = CBv2PositionState(
            promptPositionIds: MLXArray([
                Int32(0), 1, 2,
                0, 4, 5,
                0, 7, 8,
            ]).reshaped([3, 1, 3]),
            decodeDeltas: [-2])
        let input = CBv2MultimodalInput(
            spans: [CBv2ImageSpan(tokenOffset: 1, length: 1)],
            attention: .causal,
            positionState: positions
        ) { [MLXArray.ones([1, 1, 4])] }
        let stream = await bridge.submitTokenized(
            promptTokens: [1, 990, 2],
            request: ChatCompletionRequest(
                model: "test/vlm-stub",
                messages: [ChatMessage(role: "user", content: "x")],
                max_tokens: 1),
            requestId: "qwen-position-passthrough",
            multimodal: input,
            mediaKind: .image)
        for await _ in stream {}

        let submitted = try #require(engine.submitted.first)
        let submittedPositions = try #require(submitted.positionState)
        #expect(submitted.multimodal?.attention == .causal)
        #expect(submittedPositions.decodeDeltas == [-2])
        #expect(submittedPositions.promptLength == 3)
    }

    @Test("text submit keeps multimodal nil and emits no vision telemetry")
    func textSubmitUnchanged() async throws {
        let engine = VisionScriptedEngine(
            script: .stream([
                .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 0))
            ]))
        let telemetry = VisionTelemetrySink()
        let bridge = visionMakeBridge(engine: engine, telemetry: telemetry)
        let request = ChatCompletionRequest(
            model: "test/vlm-stub",
            messages: [ChatMessage(role: "user", content: "hi")],
            temperature: 0, max_tokens: 8)
        let stream = await bridge.submitTokenized(
            promptTokens: [1, 2, 3], request: request, requestId: "req-text-1")
        for await _ in stream {}
        let submitted = try #require(engine.submitted.first)
        #expect(submitted.multimodal == nil)
        #expect(
            telemetry.events.allSatisfy {
                $0.fields?["operation"]?.description != "engine_v2_vision"
            })
    }
}
