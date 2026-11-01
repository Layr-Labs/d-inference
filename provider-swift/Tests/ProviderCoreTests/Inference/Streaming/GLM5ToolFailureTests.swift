import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

#if DEBUG
@Suite("GLM tool suffix validation")
struct GLM5ToolFailureTests {
    private let valid = "<tool_call>echo<arg_key>text</arg_key><arg_value>SAFE</arg_value></tool_call>"

    @Test(arguments: [false, true], [1, 7, 4096])
    func malformedSuffixNeverCommitsEarlierCall(forced: Bool, width: Int) async throws {
        try await check(output: valid + "PRIVATE_STRAY", forced: forced, width: width, invalid: true)
    }

    @Test(arguments: [false, true])
    func truncatedSecondCallNeverCommitsEarlierCall(forced: Bool) async throws {
        try await check(output: valid + "<tool_call>echo<arg_key>text", forced: forced, width: 1, invalid: true)
    }

    @Test(arguments: [false, true])
    func validCallSurvives(forced: Bool) async throws {
        try await check(output: valid, forced: forced, width: 1, invalid: false)
    }

    @Test(arguments: [false, true])
    func oversizedFrameFailsBeforeFallback(forced: Bool) async throws {
        try await check(output: "<tool_call>echo" + String(repeating: "x", count: (1 << 20) + 1),
            forced: forced, width: 65536, invalid: true)
    }

    /// Forced choice is served by structured post-validation: the production
    /// handler is the native GLM parser, which withholds calls until EOS.
    @Test func publicForcedGLMUsesTheWithheldNativeParser() throws {
        for choice in [#""required""#, #"{"type":"function","function":{"name":"echo"}}"#] {
            let request = try MiMoConsumerFixture.request(choice: choice)
            let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "glm5_next")
            let handler = try #require(try ToolStreamPreparation.makeHandler(
                request: request, prepared: prepared, modelType: "glm5_next"))
            #expect(handler.format == .glm5 && !handler.streamsCalls)
            let context = ChatTemplateFixContext(modelId: request.model, modelType: "glm5_next")
            #expect(try ToolChoiceEnforcementPolicy.forcedStrategy(mode: prepared.mode, modelContext: context)
                == .structuredPostValidation)
            #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                try ToolChoiceEnforcementPolicy.validateParser(.json, strategy: .structuredPostValidation,
                    modelContext: context)
            }
        }
    }

    private func check(output: String, forced: Bool, width: Int, invalid: Bool) async throws {
        let request = try MiMoConsumerFixture.request(choice: forced ? #""required""# : #""auto""#)
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "glm5_next")
        let handler = try #require(try ToolStreamPreparation.makeHandler(
            request: request, prepared: prepared, modelType: "glm5_next"))
        let scheduler = MultiModelBatchSchedulerEngine(registryProvider: { [:] })
        let upstream = AsyncStream<GenerationEvent> { continuation in
            let chars = Array(output)
            for start in stride(from: 0, to: chars.count, by: width) {
                continuation.yield(.chunk(String(chars[start..<min(start + width, chars.count)])))
            }
            continuation.finish()
        }
        let stream = try scheduler._testMakeEventStream(upstream: upstream, cancelUpstream: {},
            prepared: prepared, releaseBox: OneShotRelease(release: { _ in }, modelId: "fixture"),
            toolHandler: handler)
        var calls = 0, visible = ""
        var failure: MultiModelBatchSchedulerEngineError?
        do {
            for try await event in stream {
                switch event {
                case .toolCall(let call):
                    calls += 1
                    #expect(call.function.name == "echo")
                case .content(let text): visible += text
                case .parsed(let value): visible += value.content
                default: break
                }
            }
        } catch { failure = try #require(error as? MultiModelBatchSchedulerEngineError) }
        if invalid {
            #expect(calls == 0)
            #expect(visible.isEmpty)
            #expect(failure == (forced ? .toolChoiceViolation("native GLM tool output is invalid")
                : .generationFailed("native GLM tool output is invalid")))
            if let failure { #expect(ProviderLoop.mapInferenceErrorToStatus(failure) == (forced ? 422 : 500)) }
        } else {
            #expect(failure == nil)
            #expect(calls == 1)
            #expect(visible.isEmpty)
        }
    }
}
#endif
