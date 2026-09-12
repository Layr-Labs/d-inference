import MLXLMCommon
import MLXLMServer

/// Classify native reasoning BEFORE tool parsing. Tool-like text inside a
/// reasoning block is never an invocation. Original token accounting is owned
/// by the engine; this layer only routes already generated text.
struct NativeToolStreamRouter {
    private let handler: BatchedToolStreamHandler?
    private let requiresToolCall: Bool
    private var parser: NativeChannelSplitter?

    init(handler: BatchedToolStreamHandler?, requiresToolCall: Bool, nativePrefix: String?) {
        self.handler = handler
        self.requiresToolCall = requiresToolCall
        if let nativePrefix {
            self.parser = NativeChannelSplitter(prefix: nativePrefix, protectToolFrames: handler != nil)
        }
    }

    var usesNativeChannels: Bool { parser != nil }

    mutating func process(_ text: String) throws -> [MLXServerGenerationEvent] {
        let pieces = parser != nil ? parser!.parse(text) : [.init(content: text, reasoningContent: nil)]
        return try route(pieces)
    }

    mutating func finishText() throws -> [MLXServerGenerationEvent] {
        try route(parser?.finish() ?? [])
    }

    func visibleEvent(_ text: String) -> MLXServerGenerationEvent {
        usesNativeChannels ? .parsed(.init(content: text, reasoningContent: nil)) : .content(text)
    }

    private func route(_ pieces: [ParsedReasoning]) throws -> [MLXServerGenerationEvent] {
        var events: [MLXServerGenerationEvent] = []
        for piece in pieces {
            if let reasoning = piece.reasoningContent, !reasoning.isEmpty {
                events.append(.parsed(.init(content: "", reasoningContent: reasoning)))
            }
            guard !piece.content.isEmpty else { continue }
            let visible: String?
            if let handler { visible = handler.processChunk(piece.content) }
            else { visible = piece.content }
            guard let visible, !visible.isEmpty else { continue }
            if requiresToolCall {
                if usesNativeChannels && ToolChoiceEnforcementPolicy.isFramingWhitespace(visible) { continue }
                throw MultiModelBatchSchedulerEngineError.toolChoiceViolation(
                    "forced tool_choice produced visible text before a validated call")
            }
            events.append(visibleEvent(visible))
        }
        return events
    }
}
