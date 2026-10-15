import Foundation
import MLXLMCommon
import MLXLMServer
import MLXVLM

/// Opt-in, unpublished-owner HTTP hook. No production caller installs this hook;
/// model discovery and ordinary registry/native lease policy remain unchanged.
struct NemotronSuperLocalImageHTTP: Sendable {
    private let images: NemotronSuperLocalImageBinding
    private let template: Data

    init(owner: NemotronSuperLocalBridgeBuilder.Owner, templateBytes: Data) throws {
        _ = try NemotronSuperPromptContract.verifiedTemplate(templateBytes)
        images = try owner.localImageBinding()
        template = templateBytes
    }

    func service(body: Data, request: OpenAIChatCompletionRequest,
                 responseStore: InMemoryResponseStore, metrics: ServerMetrics) -> MLXOpenAIService? {
        guard request.model == NemotronSuperLocalBinding.modelID,
            request.messages.contains(where: { message in
                guard case .parts(let parts) = message.content else { return false }
                return parts.contains { part in
                    if case .text = part { return false }
                    return true
                }
            }) else { return nil }
        return MLXOpenAIService(engine: SuperImageHTTPEngine(images: images, body: body, template: template),
                                responseStore: responseStore, metrics: metrics)
    }
}

/// A service instance owns exactly one immutable raw request. Unknown raw-body
/// controls are preserved for runEncoded's fail-closed validation.
private struct SuperImageHTTPEngine: MLXServerEngine {
    let images: NemotronSuperLocalImageBinding
    let body: Data
    let template: Data

    func availableModels() async throws -> [MLXServerModel] { [] }
    func tokenize(_ request: TokenizeRequest) async throws -> TokenizeResponse { throw unsupported() }
    func detokenize(_ request: DetokenizeRequest) async throws -> DetokenizeResponse { throw unsupported() }
    func applyTemplate(_ request: ApplyTemplateRequest) async throws -> TokenizeResponse { throw unsupported() }
    private func unsupported() -> MultiModelBatchSchedulerEngineError {
        .requestRejected("unpublished image adapter exposes only its bound chat request")
    }

    func streamChatCompletion(request: OpenAIChatCompletionRequest) async throws
        -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
        guard request.model == NemotronSuperLocalBinding.modelID else { throw unsupported() }
        let controls: [String: any Sendable]
        do { controls = try NemotronSuperPromptContract.additionalContext(body: body) }
        catch { throw Self.map(error) }
        // Until prompt-prefix/channel metadata reaches this adapter, require the
        // pinned template's explicit thinking-off mode; never label reasoning as content.
        guard controls["enable_thinking"] as? Bool == false else {
            throw MultiModelBatchSchedulerEngineError.unsupportedReasoningEffort
        }
        let pair = AsyncThrowingStream<MLXServerGenerationEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let relay = SuperImageHTTPRelay(continuation: pair.continuation)
        let scope = LocalRequestCancellation.current
        let task = Task {
            let registration = scope?.register { relay.cancel() }
            defer { registration?.remove() }
            do {
                try Task.checkCancellation()
                try await images.runEncoded(body: body, templateBytes: template) { event in
                    await relay.accept(event)
                }
                try Task.checkCancellation()
                await relay.complete()
            } catch { await relay.fail(Self.map(error)) }
        }
        relay.installCancellation { task.cancel() }
        pair.continuation.onTermination = { _ in task.cancel() }
        // Preserve pre-header error status for rejected media. This also keeps
        // transport preparation cancellation attached until a real event exists.
        try await withTaskCancellationHandler {
            try await relay.waitUntilStarted()
        } onCancel: { task.cancel() }
        return pair.stream
    }

    static func map(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let error = error as? MultiModelBatchSchedulerEngineError { return error }
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
        if error is DecodingError || error is NemotronSuperImageDecode.Failure
            || error is NemotronSuperImagePreprocessing.Failure
            || error is NemotronSuperPromptContract.Failure || error is MediaIngest.MediaError {
            return MultiModelBatchSchedulerEngineError.multimodalRejected("invalid inline image request")
        }
        // Foreign errors may contain prompt/media data; do not serialize them.
        return MultiModelBatchSchedulerEngineError.generationFailed("native image execution failed")
    }
}

/// Stream state and startup result are actor-owned. Cancellation registration
/// uses a separate lock so transport callbacks never wait on this actor.
actor SuperImageHTTPRelay {
    private let continuation: AsyncThrowingStream<MLXServerGenerationEvent, Error>.Continuation
    private var startup: Result<Void, Error>?
    private var waiter: CheckedContinuation<Void, Error>?
    private var terminal: ServerGenerationInfo?
    private var failure: Error?
    private let startedAt = Date()
    private var firstChunkAt: Date?
    private nonisolated let cancellation = SuperImageHTTPCancellation()

    init(continuation: AsyncThrowingStream<MLXServerGenerationEvent, Error>.Continuation) {
        self.continuation = continuation
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
                failure = MultiModelBatchSchedulerEngineError.generationFailed("invalid native image terminal order")
                return
            }
            if !text.isEmpty {
                if firstChunkAt == nil { firstChunkAt = Date() }
                if case .dropped = continuation.yield(.content(text)) {
                    failure = MultiModelBatchSchedulerEngineError.requestRejected("image response consumer is too slow")
                    cancel()
                } else {
                    started(.success(()))
                }
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
    func complete() {
        if let failure { fail(failure); return }
        guard let terminal else {
            fail(MultiModelBatchSchedulerEngineError.generationFailed("native image stream ended without terminal usage"))
            return
        }
        if case .dropped = continuation.yield(.info(terminal)) {
            fail(MultiModelBatchSchedulerEngineError.requestRejected("image response consumer is too slow"))
            return
        }
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
