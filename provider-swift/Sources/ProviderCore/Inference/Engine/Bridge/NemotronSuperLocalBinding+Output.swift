import Foundation
import MLXLMServer

extension NemotronSuperLocalBinding {
    /// Internal qualification route only. The supplied tokenizer must belong to
    /// the same admitted installation as acquisition. No HTTP registration.
    /// Returns only after native retirement AND complete output validation.
    func runValidatedText(body: Data, templateBytes: Data, tokenizer: TokenizerHandle,
        defaultMaxTokens: Int) async throws -> NemotronSuperLocalOutput.Result {
        let request = try ProviderLoop.decodeOpenAIRequest(body)
        guard body.count <= 4 << 20,
            let wire = try JSONSerialization.jsonObject(with: body) as? [String: Any],
            wire["logprobs"] == nil, wire["top_logprobs"] == nil,
            wire["prompt_cache_key"] == nil,
            request.minP == nil || request.minP == 0,
            let maximum = request.maxTokens, maximum > 0, maximum <= defaultMaxTokens
        else { throw Failure.unsupportedCapability }
        let template = try NemotronSuperPromptContract.verifiedTemplate(templateBytes)
        let plan = try NemotronSuperLocalOutput(request: request, nativePrefix: "")
        let tokens = try tokenizer.inner.applyChatTemplate(
            messages: NemotronSuperPromptContract.messages(plan.preparedRequest.messages),
            chatTemplate: template, tools: plan.preparedRequest.tools?.map { $0.toolSpec() },
            additionalContext: NemotronSuperPromptContract.additionalContext(body: body))
        guard let prefix = ReasoningPromptProbe.streamingPrefix(forPromptTail:
            tokenizer.inner.decode(tokenIds: Array(tokens.suffix(ReasoningPromptProbe.tailTokenCount)),
                skipSpecialTokens: false)) else { throw Failure.unsupportedCapability }
        let collector = NemotronSuperOutputCollector(try .init(request: request, nativePrefix: prefix))
        let translated = MultiModelBatchSchedulerEngine.translate(openAIRequest: request,
            defaultMaxTokens: defaultMaxTokens)
        // translate deliberately strips wire output controls; this route owns
        // them through the pinned rendered prompt and withheld validation above.
        try await run(request: translated, promptTokens: tokens) { event in
            await collector.accept(event)
        }
        try Task.checkCancellation()
        return try await collector.finish()
    }
}

actor NemotronSuperOutputCollector {
    enum Failure: Error { case invalidTerminal }
    private var output: NemotronSuperLocalOutput
    private var failure: (any Error)?
    private var terminal = false
    init(_ output: NemotronSuperLocalOutput) { self.output = output }
    func accept(_ event: GenerationEvent) {
        guard failure == nil else { return }
        do {
            switch event {
            case .chunk(let text):
                guard !terminal else { throw Failure.invalidTerminal }
                try output.append(text)
            case .info(_, _, _, let reason):
                guard !terminal, reason == nil || reason == "stop" else { throw Failure.invalidTerminal }
                terminal = true
            case .error, .terminal: throw Failure.invalidTerminal
            }
        } catch { failure = error }
    }
    func finish() throws -> NemotronSuperLocalOutput.Result {
        if let failure { throw failure }
        guard terminal else { throw Failure.invalidTerminal }
        return try output.finish()
    }
}
