import Foundation
import MLXLMServer
import XCTest
@testable import ProviderCore

final class QwenStrayThinkCloseConformanceTests: XCTestCase {
    private let flag = "DARKBLOOM_QWEN_ABSORB_STRAY_THINK_CLOSE"
    private var previous: String?
    override func setUp() {
        super.setUp()
        previous = ProcessInfo.processInfo.environment[flag]
        setenv(flag, "1", 1)
    }
    override func tearDown() {
        if let previous { setenv(flag, previous, 1) } else { unsetenv(flag) }
        super.tearDown()
    }

    private func content(_ text: String, width: Int, type: String) throws -> String {
        let absorbs = ToolChoiceEnforcementPolicy.absorbsStrayThinkClose(
            .init(modelId: "qwen3.6-35b-a3b-vl-mtp-mxfp8", modelType: type))
        var router = NativeToolStreamRouter(handler: nil, requiresToolCall: false,
            nativePrefix: "<think></think>", absorbStrayThinkClose: absorbs)
        let chars = Array(text)
        var events = [MLXServerGenerationEvent]()
        for start in stride(from: 0, to: chars.count, by: width) {
            events += try router.process(String(chars[start..<min(start + width, chars.count)]))
        }
        events += try router.finishText()
        return events.compactMap { event -> String? in
            if case .parsed(let parsed) = event {
                XCTAssertNil(parsed.reasoningContent)
                return parsed.content
            }
            XCTFail("Expected native parsed event")
            return nil
        }.joined()
    }

    func testStrayAndRepeatedClosesAreAbsorbedAtEveryChunking() throws {
        for type in ["qwen3_5", "qwen3_5_moe", "qwen4_exp", "qwen4_exp_text"] {
            for width in [1, 2, 3, 7, 4096] {
                XCTAssertEqual(try content("before</think></think>after", width: width, type: type), "beforeafter")
            }
        }
    }

    func testPartialMarkerRemainsLiteralAtEndOfStream() throws {
        XCTAssertEqual(try content("before</thi", width: 1, type: "qwen3_5"), "before</thi")
    }

    func testOnlyClosedQwenPromptsSelectTheNoToolsNativeRoute() throws {
        let context = ChatTemplateFixContext(modelId: "Qwen3.5-9B", modelType: "qwen3_5")
        XCTAssertEqual(QwenStrayThinkClose.nativePrefix("<think></think>", context: context), "<think></think>")
        for prefix in [nil, "", "<think>"] as [String?] {
            XCTAssertNil(QwenStrayThinkClose.nativePrefix(prefix, context: context))
        }
        for type in ["gpt_oss", "gemma4", "nemotron_h", "mimo_v2", "prism_hadamard_qwen35"] {
            XCTAssertNil(QwenStrayThinkClose.nativePrefix("<think></think>",
                context: .init(modelId: "Qwen3.5-9B", modelType: type)))
        }
        XCTAssertTrue(LaunchAgent.inferencePassthroughEnvKeys.contains(flag))
    }

    func testLiteralCloseInsideToolArgumentsIsPreserved() throws {
        let output = "</think><tool_call><function=save_note><parameter=body>literal </think> tag</parameter></function></tool_call>"
        for width in [1, 3, 4096] {
            let handler = BatchedToolStreamHandler(format: .qwen35, tools: nil)
            var router = NativeToolStreamRouter(handler: handler, requiresToolCall: false,
                nativePrefix: "<think></think>", absorbStrayThinkClose: true)
            let chars = Array(output)
            for start in stride(from: 0, to: chars.count, by: width) {
                _ = try router.process(String(chars[start..<min(start + width, chars.count)]))
            }
            _ = try router.finishText()
            let calls = handler.finish()
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls.first?.function.arguments["body"], .string("literal </think> tag"))
        }
    }

    func testClosedMediaPromptInstallsTheToolParserBeforeAbsorption() throws {
        let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self,
            from: Data(#"{"model":"qwen3.6-35b-a3b-vl-mtp-mxfp8","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"https://example.invalid/image.png"}}]}],"tools":[{"type":"function","function":{"name":"save_note","parameters":{"type":"object","properties":{"body":{"type":"string"}}}}}]}"#.utf8))
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "qwen3_5_moe")
        let context = ChatTemplateFixContext(modelId: request.model, modelType: "qwen3_5_moe")
        XCTAssertTrue(MediaIngest.hasMedia(request))
        let handler = try XCTUnwrap(QwenStrayThinkClose.mediaToolHandler(existing: nil,
            prefix: "<think></think>", request: request, prepared: prepared, context: context))
        var router = NativeToolStreamRouter(handler: handler, requiresToolCall: false,
            nativePrefix: QwenStrayThinkClose.nativePrefix("<think></think>", context: context),
            absorbStrayThinkClose: ToolChoiceEnforcementPolicy.absorbsStrayThinkClose(context))
        let output = "</think><tool_call><function=save_note><parameter=body>literal </think> tag</parameter></function></tool_call>"
        for char in output { _ = try router.process(String(char)) }
        _ = try router.finishText()
        XCTAssertEqual(handler.finish().first?.function.arguments["body"], .string("literal </think> tag"))
        for prefix in [nil, "<think>"] as [String?] {
            XCTAssertNil(try QwenStrayThinkClose.mediaToolHandler(existing: nil,
                prefix: prefix, request: request, prepared: prepared, context: context))
        }
        setenv(flag, "0", 1)
        XCTAssertNil(try QwenStrayThinkClose.mediaToolHandler(existing: nil,
            prefix: "<think></think>", request: request, prepared: prepared, context: context))
    }

    #if DEBUG
    func testThinkingOffNoToolsEngineStreamSuppressesCompleteCloses() async throws {
        let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self,
            from: Data(#"{"model":"Qwen3.5-9B","messages":[{"role":"user","content":"Hi"}],"stream":true,"reasoning_parser":"qwen3"}"#.utf8))
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "qwen3_5")
        let context = ChatTemplateFixContext(modelId: request.model, modelType: "qwen3_5")
        let output = "before</think></think>after</thi"
        let upstream = AsyncStream<GenerationEvent> { continuation in
            for char in output { continuation.yield(.chunk(String(char))) }
            continuation.yield(.info(promptTokens: 9, completionTokens: output.count,
                tokensPerSecond: 0, finishReason: "stop"))
            continuation.finish()
        }
        let stream = try MultiModelBatchSchedulerEngine(registryProvider: { [:] })._testMakeEventStream(
            upstream: upstream, cancelUpstream: {}, prepared: prepared,
            releaseBox: OneShotRelease(release: { _ in }, modelId: request.model),
            reasoningPrefix: "<think></think>",
            nativeReasoningPrefix: QwenStrayThinkClose.nativePrefix("<think></think>", context: context),
            absorbStrayThinkClose: ToolChoiceEnforcementPolicy.absorbsStrayThinkClose(context))
        var content = ""
        for try await event in stream {
            if case .parsed(let part) = event {
                content += part.content
                XCTAssertNil(part.reasoningContent)
            }
        }
        XCTAssertEqual(content, "beforeafter</thi")
    }
    #endif

    /// The kill switch: an off word restores 0.10.12, where the close stays literal.
    func testSwitchOffWordsPreserveLiteralClose() throws {
        for value in ["0", "off", "false", "no", "none", "disabled", " OFF "] {
            setenv(flag, value, 1)
            XCTAssertEqual(try content("before</think>after", width: 1, type: "qwen3_5"), "before</think>after", value)
            XCTAssertNil(QwenStrayThinkClose.nativePrefix("<think></think>",
                context: .init(modelId: "Qwen3.5-9B", modelType: "qwen3_5")), value)
        }
    }

    /// On by default for the Qwen types: unset, empty or any other value absorbs.
    func testAbsorptionIsOnByDefault() throws {
        unsetenv(flag)
        let context = ChatTemplateFixContext(modelId: "Qwen3.5-9B", modelType: "qwen3_5")
        XCTAssertEqual(try content("before</think>after", width: 1, type: "qwen3_5"), "beforeafter")
        XCTAssertEqual(QwenStrayThinkClose.nativePrefix("<think></think>", context: context), "<think></think>")
        for value in ["", "1", "on", "garbage"] {
            setenv(flag, value, 1)
            XCTAssertEqual(try content("before</think>after", width: 1, type: "qwen3_5_moe"), "beforeafter", value)
        }
        unsetenv(flag)
        for type in ["gpt_oss", "gemma4", "nemotron_h", "mimo_v2", "prism_hadamard_qwen35"] {
            XCTAssertFalse(QwenStrayThinkClose.applies(.init(modelId: "Qwen3.5-9B", modelType: type)), type)
        }
    }
}
