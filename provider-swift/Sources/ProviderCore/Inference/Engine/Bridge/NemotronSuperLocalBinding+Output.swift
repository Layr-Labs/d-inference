import Foundation
import MLXLMServer

extension NemotronSuperLocalBinding {
    /// Internal qualification route only. The supplied tokenizer must belong to
    /// the same admitted installation as acquisition. No HTTP registration.
    /// Returns only after native retirement AND complete output validation;
    /// output is split as one complete (non-streaming) response.
    func runValidatedText(body: Data, templateBytes: Data, tokenizer: TokenizerHandle,
        defaultMaxTokens: Int) async throws -> NemotronSuperLocalOutput.Result {
        guard body.count <= 4 << 20 else { throw Failure.unsupportedCapability }
        let plan = try NemotronSuperRequestPlan(body: body)
        guard let maximum = plan.request.maxTokens, maximum > 0, maximum <= defaultMaxTokens else {
            throw Failure.unsupportedCapability
        }
        let tokens = try plan.textPromptTokens(body: body, templateBytes: templateBytes,
                                               tokenizer: tokenizer.inner)
        let collector = NemotronSuperOutputCollector(try .init(plan: plan, streaming: false))
        // translate deliberately strips wire output controls; this route owns
        // them through the pinned rendered prompt and withheld validation.
        let translated = MultiModelBatchSchedulerEngine.translate(openAIRequest: plan.request,
            defaultMaxTokens: defaultMaxTokens)
        try await run(request: translated, promptTokens: tokens) { event in
            await collector.accept(event)
        }
        try Task.checkCancellation()
        return try await collector.finish()
    }
}

/// Validated collection refuses truncation: a length-limited answer cannot
/// prove a complete tool call or structured value.
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
                _ = try output.append(text)
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
        return try output.finish().result
    }
}
