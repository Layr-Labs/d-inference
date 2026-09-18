// Copyright © 2026 Eigen Labs.
import Foundation
import MLX
@_spi(Benchmarking) @testable import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

/// Actual vision preparation plus native row ownership. API framing/semantics
/// are separate gates; this fixture compares every emitted native token with
/// isolated execution while requests join, finish and cancel.
enum BonsaiMediaCohortQualification {
    private struct Output: Sendable {
        var tokens: [Int] = []
        var finish: CBv2FinishReason?
    }

    private static func collect(_ stream: AsyncStream<CBv2Event>) async -> Output {
        var result = Output()
        for await event in stream {
            switch event {
            case .delta(_, let tokens, _): result.tokens += tokens
            case .finished(let reason, _): result.finish = reason
            }
        }
        return result
    }

    private static func waitForStep(_ target: Int, engine: EngineV2) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while engine.capacity().stepsExecuted < target && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(engine.capacity().stepsExecuted >= target)
    }

    static func run(container: ModelContainer, model: any LanguageModel,
                    tokenizer: any MLXLMCommon.Tokenizer) async throws {
        let redPNG = "data:image/png;base64,"
            + "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAb0lEQVR4nO3PAQkAAAyEwO9feoshgnABdLep8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3IPanc8OLDQitxAAAAAElFTkSuQmCC"
        let blueClip = try await makeSolidColorClip(
            colors: Array(repeating: (r: 0, g: 0, b: 255), count: 4), fps: 2)
        let toolBody: [String: Any] = ["model": "ternary-bonsai-2-27b", "messages": [[
            "role": "user", "content": [["type": "text", "text": "Use report_color to report the image color."],
                ["type": "image_url", "image_url": ["url": redPNG]]]]],
            "tools": [["type": "function", "function": ["name": "report_color",
                "description": "Report image color", "parameters": ["type": "object",
                    "properties": ["color": ["type": "string"]], "required": ["color"]]]]],
            "reasoning": ["effort": "none"], "temperature": 0, "max_tokens": 24]
        let toolRequest = try JSONDecoder().decode(OpenAIChatCompletionRequest.self,
            from: JSONSerialization.data(withJSONObject: toolBody))
        let image = try await EngineV2VisionPrefill.prepare(container: container, request: toolRequest)
        let video = try await EngineV2VisionPrefill.prepare(container: container,
            request: OpenAIChatCompletionRequest(model: "ternary-bonsai-2-27b",
                messages: [.init(role: .user, content: .parts([
                    .text("Describe the clip's solid color."), .videoURL(dataURI(forMP4: blueClip))]))],
                temperature: 0, maxTokens: 32))
        #expect(image.mediaKind == .image && video.mediaKind == .video)
        #expect(!image.embeddings.isEmpty && !video.embeddings.isEmpty)
        #expect(image.positionState != nil && video.positionState != nil)
        let built = try EngineV2Factory.makeProductionBuild(model: model,
            modelID: "ternary-bonsai-2-27b", tokenizer: tokenizer,
            kvBytesCapacity: 4 << 30, maxConcurrentRequests: 3,
            kvBackend: .paged, maxContextLength: 8192)
        let engine = try #require(built.engine as? EngineV2)
        let a = CBv2Request(id: .init(31), promptTokens: image.promptTokens,
            sampling: .init(temperature: 0), maxTokens: 24,
            multimodal: image.multimodalInput(), positionState: image.positionState)
        let b = CBv2Request(id: .init(32), promptTokens: (0..<521).map { 37 + $0 % 500 },
            sampling: .init(temperature: 0), maxTokens: 40)
        let c = CBv2Request(id: .init(33), promptTokens: video.promptTokens,
            sampling: .init(temperature: 0), maxTokens: 32,
            multimodal: video.multimodalInput(), positionState: video.positionState)
        do {
            let serialA = await collect(try engine.submit(a))
            let serialB = await collect(try engine.submit(b))
            let serialC = await collect(try engine.submit(c))
            try await BonsaiNativeFixtureDrain.require(engine)
            #expect(serialA.finish == .length && serialB.finish == .length && serialC.finish == .length)
            let observation = try engine.beginForwardShapeObservation()
            let joinStep = engine.loopForTesting.onEngineQueueSync { () -> Int in
                let target = engine.loopForTesting.stepCount + 5
                engine.loopForTesting.suspendStepExecutionAtCountForTesting = target
                return target
            }
            let aStream = try engine.submit(a), bStream = try engine.submit(b)
            try await waitForStep(joinStep, engine: engine)
            try #require(engine.capacity().activeRequests == 2)
            let cStream = try engine.submit(c)
            engine.loopForTesting.onEngineQueueSync {
                engine.loopForTesting.suspendStepExecutionAtCountForTesting = nil
            }
            async let aa = collect(aStream), bb = collect(bStream), cc = collect(cStream)
            let (pairedA, pairedB, pairedC) = await (aa, bb, cc)
            #expect(pairedA.tokens == serialA.tokens && pairedB.tokens == serialB.tokens && pairedC.tokens == serialC.tokens)
            #expect(pairedA.finish == .length && pairedB.finish == .length && pairedC.finish == .length)
            try await BonsaiNativeFixtureDrain.require(engine)
            let delta = engine.forwardShapeSnapshot().delta(since: observation)
            print("BONSAI_MEDIA_COHORT shapes=" + String(decoding: try JSONEncoder().encode(delta), as: UTF8.self))
            #expect(delta.complete && delta.reasons.isEmpty)
            #expect(delta.entries.contains {
                $0.axes.phase == .decode && $0.axes.liveBatchRows == 3 && $0.completedCalls > 0
            })

            // Repeat with image cancellation while text is live. The surviving
            // row and subsequent reuse of the cancelled ID must be unchanged.
            let cancelStep = engine.loopForTesting.onEngineQueueSync { () -> Int in
                let target = engine.loopForTesting.stepCount + 5
                engine.loopForTesting.suspendStepExecutionAtCountForTesting = target
                return target
            }
            let cancelledStream = try engine.submit(a), survivorStream = try engine.submit(b)
            try await waitForStep(cancelStep, engine: engine)
            engine.cancel(a.id)
            engine.loopForTesting.onEngineQueueSync {
                engine.loopForTesting.suspendStepExecutionAtCountForTesting = nil
            }
            async let cancelled = collect(cancelledStream), survivor = collect(survivorStream)
            let (cancelResult, survivorResult) = await (cancelled, survivor)
            #expect(cancelResult.finish == .cancelled)
            #expect(serialA.tokens.starts(with: cancelResult.tokens))
            #expect(survivorResult.tokens == serialB.tokens && survivorResult.finish == .length)
            let reused = await collect(try engine.submit(a))
            #expect(reused.tokens == serialA.tokens && reused.finish == .length)
            try await BonsaiNativeFixtureDrain.require(engine)
            await engine.shutdown()
            print("BONSAI_MEDIA_COHORT phase_completed; framework assertions determine verdict")
        } catch {
            engine.loopForTesting.onEngineQueueSync {
                engine.loopForTesting.suspendStepExecutionAtCountForTesting = nil
            }
            await engine.shutdown()
            throw error
        }
    }
}
