import Foundation
import MLXLMCommon
import MLXLMServer

/// Unregistered per-request qualification path. Buffers every channel until the
/// parser and shared validators accept the result. Does not grant model support,
/// sampler grammar support, or tool execution authority.
struct NemotronSuperLocalOutput {
    enum Failure: Error { case invalidRequest, limit, alreadyFinished, malformedToolFrame }
    struct Result {
        let content: String
        let reasoning: String
        let calls: [ToolCall]
    }
    let preparedRequest: OpenAIChatCompletionRequest
    let toolPolicy: ToolChoicePromptPolicy.Prepared
    private let handler: BatchedToolStreamHandler
    private var router: NativeToolStreamRouter
    private var content = ""
    private var reasoning = ""
    private var receivedBytes = 0
    private var finished = false
    private let maximumBytes: Int

    init(request: OpenAIChatCompletionRequest, nativePrefix: String,
        maximumBytes: Int = 1 << 20) throws {
        guard request.model == NemotronSuperLocalBinding.modelID,
            maximumBytes > 0, maximumBytes <= 16 << 20,
            !MediaIngest.hasMedia(request),
            !(request.responseFormat?.requiresJSONOutput == true && request.tools?.isEmpty == false)
        else { throw Failure.invalidRequest }
        let formatted = try OpenAIResponseFormatSupport.preparedRequest(request)
        let prepared = try ToolChoicePromptPolicy.prepare(formatted,
            modelType: "nemotron_h_omni", allowInternalSchemaMetadata: false)
        var rendered = formatted
        rendered.messages = prepared.messages
        rendered.tools = prepared.tools
        let tools: [[String: any Sendable]]? = prepared.tools?.map { tool in
            // The same OpenAI tool contract consumed by the pinned template.
            tool.toolSpec()
        }
        let handler = BatchedToolStreamHandler(format: .nemotron, tools: tools)
        self.handler = handler
        self.router = NativeToolStreamRouter(handler: handler,
            requiresToolCall: prepared.requiresToolCall, nativePrefix: nativePrefix,
            absorbStrayThinkClose: true)
        self.preparedRequest = rendered
        self.toolPolicy = prepared
        self.maximumBytes = maximumBytes
    }

    mutating func append(_ chunk: String) throws {
        guard !finished else { throw Failure.alreadyFinished }
        guard chunk.utf8.count <= maximumBytes - receivedBytes else {
            finished = true; throw Failure.limit
        }
        receivedBytes += chunk.utf8.count
        do { collect(try router.process(chunk)) }
        catch { finished = true; throw error }
    }

    mutating func finish() throws -> Result {
        guard !finished else { throw Failure.alreadyFinished }
        finished = true
        collect(try router.finishText())
        let calls = handler.finish()
        let residual = handler.takeResidualText() ?? ""
        guard handler.parseFailureCount == 0,
            !toolPolicy.requiresToolCall || ToolChoiceEnforcementPolicy.isFramingWhitespace(residual)
        else { throw Failure.malformedToolFrame }
        content += residual
        try ToolConstraintValidation.validate(calls, prepared: toolPolicy)
        let normalized = try OpenAIResponseFormatSupport.normalizedContent(
            content, for: preparedRequest.responseFormat)
        return Result(content: normalized, reasoning: reasoning, calls: calls)
    }

    private mutating func collect(_ events: [MLXServerGenerationEvent]) {
        for event in events {
            switch event {
            case .content(let text): content += text
            case .parsed(let parsed):
                content += parsed.content
                reasoning += parsed.reasoningContent ?? ""
            case .toolCall, .info: break
            }
        }
    }
}
