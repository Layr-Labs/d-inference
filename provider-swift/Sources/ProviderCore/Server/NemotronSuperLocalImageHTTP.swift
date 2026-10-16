import Foundation
import Jinja
import MLXLMCommon
import MLXLMServer
import MLXVLM

/// Opt-in, unpublished-owner HTTP hook for Super chat requests. Text renders
/// with the owner's own tokenizer and runs on its text binding; inline images
/// run on the owner's image binding. Both stream through the reference
/// reasoning, tool and structured-output parsers. An owner with text
/// speculation installed has no image binding, so media requests get 400. No
/// production caller installs this hook; model discovery and registry/native
/// lease policy remain unchanged. The type name predates text support;
/// `LocalInferenceHTTP` plumbs it.
struct NemotronSuperLocalImageHTTP: Sendable {
    private let images: NemotronSuperLocalImageBinding?
    private let text: NemotronSuperLocalBinding
    private let tokenizer: TokenizerHandle
    private let template: Data
    private let owner: NemotronSuperLocalBridgeBuilder.Owner

    init(owner: NemotronSuperLocalBridgeBuilder.Owner, templateBytes: Data) throws {
        _ = try NemotronSuperPromptContract.verifiedTemplate(templateBytes)
        // The owner's own bindings: no lease or slot is manufactured, and both
        // refuse once the owner closes or retains a fault.
        text = try owner.localTextBinding()
        images = owner.speculates ? nil : try owner.localImageBinding()
        tokenizer = owner.bridge.tokenizer
        template = templateBytes
        self.owner = owner
    }

    /// Rejects new text work and joins it. `Owner.closeAfterDrain()` drains
    /// this text binding again, then the image binding, before retirement.
    func drain() async { await text.drain() }

    func service(body: Data, request: OpenAIChatCompletionRequest,
                 responseStore: InMemoryResponseStore, metrics: ServerMetrics) -> MLXOpenAIService? {
        guard request.model == NemotronSuperLocalBinding.modelID else { return nil }
        let route: SuperHTTPEngine.Route
        if !MediaIngest.hasMedia(request) {
            route = .text(text, tokenizer)
        } else if let images {
            route = .image(images)
        } else {
            route = .mediaRefused
        }
        return MLXOpenAIService(
            engine: SuperHTTPEngine(route: route, body: body, template: template, owner: owner),
            responseStore: responseStore, metrics: metrics)
    }
}


/// A service instance owns exactly one immutable raw request. Unknown raw-body
/// controls are preserved for the plan's and owners' fail-closed validation.
private struct SuperHTTPEngine: MLXServerEngine {
    enum Route: Sendable {
        case text(NemotronSuperLocalBinding, TokenizerHandle)
        case image(NemotronSuperLocalImageBinding)
        /// Text speculation is installed; its target refuses media embeddings.
        case mediaRefused
    }
    let route: Route
    let body: Data
    let template: Data
    let owner: NemotronSuperLocalBridgeBuilder.Owner

    func availableModels() async throws -> [MLXServerModel] { [] }
    func tokenize(_ request: TokenizeRequest) async throws -> TokenizeResponse { throw unsupported() }
    func detokenize(_ request: DetokenizeRequest) async throws -> DetokenizeResponse { throw unsupported() }
    func applyTemplate(_ request: ApplyTemplateRequest) async throws -> TokenizeResponse { throw unsupported() }
    private func unsupported() -> MultiModelBatchSchedulerEngineError {
        .requestRejected("unpublished Super owner exposes only its bound chat request")
    }

    /// `request` already carries the service's response-format instruction.
    func streamChatCompletion(request: OpenAIChatCompletionRequest) async throws
        -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
        guard request.model == NemotronSuperLocalBinding.modelID else { throw unsupported() }
        let media = if case .text = route { false } else { true }
        let output: NemotronSuperLocalOutput
        let execute: @Sendable (@escaping @Sendable (GenerationEvent) async -> Void) async throws -> Void
        do {
            let plan = try NemotronSuperRequestPlan(body: body, formatted: request)
            output = try NemotronSuperLocalOutput(plan: plan, streaming: request.stream == true)
            switch route {
            case .mediaRefused:
                throw MultiModelBatchSchedulerEngineError.mediaUnsupportedByModel(
                    NemotronSuperLocalBinding.modelID)
            case .image(let images):
                let body = self.body, template = self.template
                execute = { onEvent in try await images.runEncoded(body: body, templateBytes: template, onEvent: onEvent) }
            case .text(let binding, let tokenizer):
                // Rendered before headers: template and tool errors keep their status.
                let tokens = try plan.textPromptTokens(body: body, templateBytes: template,
                                                       tokenizer: tokenizer.inner)
                // translate keeps the request's max_tokens (nil: the bridge default).
                let translated = MultiModelBatchSchedulerEngine.translate(
                    openAIRequest: plan.request, defaultMaxTokens: 1)
                execute = { onEvent in
                    try await binding.run(request: translated, promptTokens: tokens, onEvent: onEvent)
                }
            }
        } catch { throw SuperHTTPErrors.map(error, media: media) }
        // The owner admits its configured concurrency; an image would otherwise
        // reserve and prepare media only for the bridge to refuse it.
        guard owner.admitLocalRequest() else {
            throw MultiModelBatchSchedulerEngineError.queueFull("unpublished Super owner is busy")
        }
        let pair = AsyncThrowingStream<MLXServerGenerationEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let relay = SuperImageHTTPRelay(continuation: pair.continuation, output: output)
        let scope = LocalRequestCancellation.current
        let owner = self.owner
        let task = Task {
            let registration = scope?.register { relay.cancel() }
            defer { registration?.remove(); owner.finishLocalRequest() }
            do {
                try Task.checkCancellation()
                try await execute { event in await relay.accept(event) }
                try Task.checkCancellation()
                await relay.complete()
            } catch { await relay.fail(SuperHTTPErrors.map(error, media: media)) }
        }
        relay.installCancellation { task.cancel() }
        pair.continuation.onTermination = { _ in task.cancel() }
        // Preserve pre-header error status for rejected requests. This also keeps
        // transport preparation cancellation attached until a real event exists.
        try await withTaskCancellationHandler {
            try await relay.waitUntilStarted()
        } onCancel: { task.cancel() }
        return pair.stream
    }
}

/// Outward errors never serialize foreign descriptions, which may contain
/// prompt, media or tool data.
enum SuperHTTPErrors {
    static func map(_ error: Error, media: Bool) -> Error {
        if error is CancellationError { return error }
        if error is MultiModelBatchSchedulerEngineError || error is MLXOpenAIServiceError { return error }
        if let failure = error as? NemotronSuperLocalImageBinding.Failure {
            switch failure {
            case .capacity: return MultiModelBatchSchedulerEngineError.mediaMemoryUnavailable
            case .busy: return MultiModelBatchSchedulerEngineError.queueFull("unpublished image owner is busy")
            case .closed, .retainedFault:
                return MultiModelBatchSchedulerEngineError.requestRejected("unpublished image owner is unavailable")
            case .wrongModel, .unsupportedCapability, .invalidInput:
                return MultiModelBatchSchedulerEngineError.multimodalRejected("unsupported or invalid inline image request")
            }
        }
        if let failure = error as? NemotronSuperLocalBinding.Failure {
            switch failure {
            case .drained, .missingBridge:
                return MultiModelBatchSchedulerEngineError.requestRejected("unpublished Super owner is unavailable")
            case .wrongModel, .unsupportedCapability, .invalidTokens:
                return invalidRequest(media: media)
            }
        }
        if error is NemotronSuperLocalBridgeBuilder.Failure {
            return MultiModelBatchSchedulerEngineError.requestRejected("unpublished Super owner is unavailable")
        }
        if let failure = error as? NemotronSuperLocalOutput.Failure {
            switch failure {
            case .malformedToolFrame:
                return MultiModelBatchSchedulerEngineError.toolChoiceViolation("native tool output is malformed")
            case .limit:
                return MultiModelBatchSchedulerEngineError.generationFailed("native output exceeded its bound")
            case .invalidRequest, .alreadyFinished:
                return MultiModelBatchSchedulerEngineError.generationFailed("native output handling failed")
            }
        }
        if error is DecodingError || error is NemotronSuperImageDecode.Failure
            || error is NemotronSuperImagePreprocessing.Failure || error is MediaIngest.MediaError
            || error is NemotronSuperPromptContract.Failure || error is NemotronSuperRequestPlan.Failure
            || error is NemotronSuperOrderedJSON.Failure || error is JinjaError {
            return invalidRequest(media: media)
        }
        return MultiModelBatchSchedulerEngineError.generationFailed(
            media ? "native image execution failed" : "native text execution failed")
    }

    private static func invalidRequest(media: Bool) -> Error {
        media ? MultiModelBatchSchedulerEngineError.multimodalRejected("invalid inline image request")
            : MultiModelBatchSchedulerEngineError.invalidToolPayload(
                "unsupported or contradictory Nemotron Super request")
    }
}

/// Stream state and startup result are actor-owned. Cancellation registration
/// uses a separate lock so transport callbacks never wait on this actor.
/// Every native chunk passes the request's output parser before it is yielded.
/// Parser and validator errors map identically for text and image routes, so
/// the relay maps them with `media: false`.
actor SuperImageHTTPRelay {
    private let continuation: AsyncThrowingStream<MLXServerGenerationEvent, Error>.Continuation
    private var output: NemotronSuperLocalOutput
    private var startup: Result<Void, Error>?
    private var waiter: CheckedContinuation<Void, Error>?
    private var terminal: ServerGenerationInfo?
    private var failure: Error?
    private let startedAt = Date()
    private var firstChunkAt: Date?
    private nonisolated let cancellation = SuperImageHTTPCancellation()

    init(continuation: AsyncThrowingStream<MLXServerGenerationEvent, Error>.Continuation,
         output: NemotronSuperLocalOutput) {
        self.continuation = continuation
        self.output = output
    }
    nonisolated func installCancellation(_ action: @escaping @Sendable () -> Void) { cancellation.install(action) }
    nonisolated func cancel() { cancellation.cancel() }
    func waitUntilStarted() async throws {
        if let startup { return try startup.get() }
        try await withCheckedThrowingContinuation { waiter = $0 }
    }
    private func started(_ result: Result<Void, Error>) {
        guard startup == nil else { return }
        startup = result
        waiter?.resume(with: result); waiter = nil
    }
    func accept(_ event: GenerationEvent) {
        guard failure == nil else { return }
        switch event {
        case .chunk(let text):
            guard terminal == nil else {
                failure = MultiModelBatchSchedulerEngineError.generationFailed("invalid native terminal order")
                return
            }
            guard !text.isEmpty else { return }
            if firstChunkAt == nil { firstChunkAt = Date() }
            do { yield(try output.append(text)) }
            catch {
                failure = SuperHTTPErrors.map(error, media: false)
                cancel()
            }
        case .info(let prompt, let completion, _, let reason):
            terminal = .init(promptTokens: prompt, completionTokens: completion,
                promptTime: (firstChunkAt ?? Date()).timeIntervalSince(startedAt),
                generationTime: firstChunkAt.map { Date().timeIntervalSince($0) } ?? 0,
                stopReason: reason ?? "stop", cachedPromptTokens: 0)
        case .error(let message):
            failure = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(message)
        case .terminal(let cause, let message, let prompt, let completion):
            failure = MultiModelBatchSchedulerEngineError.platformTerminal(cause: cause, message: message,
                attemptUsage: .init(promptTokens: UInt64(max(0, prompt)), completionTokens: UInt64(max(0, completion)), reasoningTokens: 0))
        }
    }
    /// Validation runs only after native terminal usage; held tool calls and
    /// structured content leave only if it succeeds.
    func complete() {
        if let failure { fail(failure); return }
        guard let terminal else {
            fail(MultiModelBatchSchedulerEngineError.generationFailed("native stream ended without terminal usage"))
            return
        }
        do { yield(try output.finish().events) }
        catch { fail(SuperHTTPErrors.map(error, media: false)); return }
        if let failure { fail(failure); return }
        yield([.info(terminal)])
        if let failure { fail(failure); return }
        cancellation.clear()
        started(.success(()))
        continuation.finish()
    }
    func fail(_ error: Error) {
        // Backpressure cancellation must not replace its original diagnosis.
        let terminalError = failure ?? error
        cancellation.clear()
        started(.failure(terminalError))
        continuation.finish(throwing: terminalError)
    }
    private func yield(_ events: [MLXServerGenerationEvent]) {
        for event in events {
            guard failure == nil else { return }
            if case .dropped = continuation.yield(event) {
                failure = MultiModelBatchSchedulerEngineError.requestRejected("image response consumer is too slow")
                cancel()
            } else {
                started(.success(()))
            }
        }
    }
}

private final class SuperImageHTTPCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    private var cancelled = false
    func install(_ action: @escaping @Sendable () -> Void) {
        let run = lock.withLock { self.action = action; return cancelled }
        if run { action() }
    }
    func clear() { lock.withLock { action = nil } }
    func cancel() {
        let callback = lock.withLock { cancelled = true; return action }
        callback?()
    }
}
