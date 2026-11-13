// Copyright © 2026 Eigen Labs.

import Foundation

/// Experimental, unregistered local qualification boundary. The acquisition closure MUST
/// come from the existing atomic provider acquire path after its container/bridge builder
/// has gained a qualified Super adapter. Installing SDK weights alone cannot provide it.
/// This type neither loads weights nor manufactures admission, trust, or registry entries.
private extension ChatCompletionRequest {
    /// The same request with another output budget.
    func withMaxTokens(_ maxTokens: Int) -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: model, messages: messages, temperature: temperature, top_p: top_p, top_k: top_k,
            max_tokens: maxTokens, repetition_penalty: repetition_penalty, presence_penalty: presence_penalty,
            frequency_penalty: frequency_penalty, stream: stream, stop: stop, seed: seed, tools: tools,
            tool_choice: tool_choice, response_format: response_format, user: user,
            prompt_cache_key: prompt_cache_key, logit_bias: logit_bias, logprobs: logprobs,
            top_logprobs: top_logprobs, min_p: min_p)
    }
}

/// Cancels the request's running row: the first, or once a continuation can
/// start, both (`LoopExitThinkingContinuation.splice`'s cancel).
private final class RowCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var action: @Sendable () async -> Void

    init(_ action: @escaping @Sendable () async -> Void) { self.action = action }

    func replace(with action: @escaping @Sendable () async -> Void) { lock.withLock { self.action = action } }

    func run() async {
        let action = lock.withLock { self.action }
        await action()
    }
}

actor NemotronSuperLocalBinding {
    /// The qualification hook's model id; a managed slot serves its registry id.
    static let modelID = "nvidia/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-NVFP4"
    enum Failure: Error, Equatable {
        case drained, wrongModel, unsupportedCapability, invalidTokens, missingBridge
    }
    typealias Acquire = @Sendable (String) async throws -> MultiModelBatchSchedulerEngine.AcquiredModel
    /// Internal fixture seam; production uses the bridge's real retirement barrier
    /// below. The `String?` is the request's prefix-cache scope (nil: no reuse);
    /// the channel receives a logprobs request's entries; the guard is the
    /// request's loop guard (nil: none).
    typealias Execute = @Sendable (EngineV2Bridge, [Int], ChatCompletionRequest, String, String?,
        EngineV2LogprobsChannel?, EngineV2RequestUsageSignal?, SSDCheckpointDonationDemand?,
        GenerationLoopGuard?, @escaping @Sendable (GenerationEvent) async -> Void) async throws -> Void

    /// The id requests must name and the acquired bridge must serve.
    let modelID: String
    private let acquire: Acquire
    private let execute: Execute
    private var draining = false
    private var active: [UUID: Task<Void, Error>] = [:]

    /// `reusesTextPrefixes` submits text with prefix caching on; only an owner
    /// whose engine has an exact checkpoint bank sets it. Otherwise text is cold.
    init(modelID: String = NemotronSuperLocalBinding.modelID, acquire: @escaping Acquire,
         reusesTextPrefixes: Bool = false) {
        self.modelID = modelID
        self.acquire = acquire
        self.execute = { bridge, tokens, request, requestID, cacheScope, logprobs, usageSignal,
                         donationDemand, loopGuard, onEvent in
            try await Self.executeBridge(bridge: bridge, tokens: tokens, request: request,
                requestID: requestID, cacheScope: reusesTextPrefixes ? cacheScope : nil,
                logprobs: logprobs, usageSignal: usageSignal, donationDemand: donationDemand,
                loopGuard: loopGuard, onEvent: onEvent)
        }
    }

    #if DEBUG
    /// TEST SEAM (debug builds only): replaces the bridge execution.
    init(modelID: String = NemotronSuperLocalBinding.modelID, acquire: @escaping Acquire,
         fixtureExecution: @escaping Execute) {
        self.modelID = modelID
        self.acquire = acquire
        self.execute = fixtureExecution
    }
    #endif

    /// Tokens must already be rendered by the qualified pinned tokenizer/chat template.
    /// No media, MTP, structured output, or tool capability is claimed here; prefix
    /// reuse only as the owner configured it at construction, partitioned by
    /// `cacheScope` (an authenticated tenant scope, or the local application's;
    /// nil disables reuse for this request). A `logprobs` request needs the
    /// `logprobs` channel its entries leave on. `usageSignal`, one per request,
    /// receives the engine's prefix-cache outcome and drives its receipts;
    /// `donationDemand` is the coordinator's fleet repeat hint for a durable
    /// checkpoint write (nil: write). `loopGuard` stops a row that repeats
    /// verbatim (`NemotronSuperRequestPlan.loopGuard()`; nil: none); one that
    /// carries an exit continues a thought it stopped as the scheduler's text
    /// path does (`LoopExitThinkingContinuation`), within this request.
    func run(request: ChatCompletionRequest, promptTokens: [Int],
             hasMedia: Bool = false, cacheScope: String? = "", logprobs: EngineV2LogprobsChannel? = nil,
             usageSignal: EngineV2RequestUsageSignal? = nil,
             donationDemand: SSDCheckpointDonationDemand? = nil,
             loopGuard: GenerationLoopGuard? = nil,
             onEvent: @escaping @Sendable (GenerationEvent) async -> Void) async throws {
        guard !draining else { throw Failure.drained }
        guard request.model == modelID else { throw Failure.wrongModel }
        guard !hasMedia, !promptTokens.contains(18), request.tools == nil, request.tool_choice == nil,
              request.response_format == nil, request.logprobs != true || logprobs != nil,
              request.prompt_cache_key == nil
        else { throw Failure.unsupportedCapability }
        guard !promptTokens.isEmpty, promptTokens.allSatisfy({ (0..<131072).contains($0) })
        else { throw Failure.invalidTokens }
        let id = UUID()
        let acquire = self.acquire
        let execute = self.execute
        let modelID = self.modelID
        let task = Task<Void, Error> {
            try Task.checkCancellation()
            let acquired = try await acquire(modelID)
            try await Self.runAcquired(acquired, modelID: modelID, execute: execute, tokens: promptTokens,
                request: request, requestID: id.uuidString, cacheScope: cacheScope, logprobs: logprobs,
                usageSignal: usageSignal, donationDemand: donationDemand, loopGuard: loopGuard, onEvent: onEvent)
        }
        active[id] = task
        defer { active.removeValue(forKey: id) }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Reject new work, cancel owned requests, and wait for their acquisition/retirement.
    /// Shared registry-owned bridges are never shut down by this binding.
    func drain() async {
        draining = true
        let tasks = Array(active.values)
        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.result }
    }

    private static func runAcquired(
        _ acquired: consuming MultiModelBatchSchedulerEngine.AcquiredModel, modelID: String,
        execute: @escaping Execute, tokens: [Int], request: ChatCompletionRequest,
        requestID: String, cacheScope: String?, logprobs: EngineV2LogprobsChannel?,
        usageSignal: EngineV2RequestUsageSignal?, donationDemand: SSDCheckpointDonationDemand?,
        loopGuard: GenerationLoopGuard?, onEvent: @escaping @Sendable (GenerationEvent) async -> Void
    ) async throws {
        guard let lease = acquired.nativeConsumerLease else {
            return try await executeAcquired(acquired, modelID: modelID, execute: execute, tokens: tokens,
                request: request, requestID: requestID, cacheScope: cacheScope, logprobs: logprobs,
                usageSignal: usageSignal, donationDemand: donationDemand, loopGuard: loopGuard, onEvent: onEvent)
        }
        let release = acquired.releaseToken
        guard release.nativeBindingAccepted else { throw NativeLocalConsumerOwnershipError.invalidBinding }
        let payload = NativeLocalAcquisitionPayload(consume acquired)
        // This API forwards callbacks inline: no stream or model-using child escapes
        // the preparation task. Its actual task join therefore covers the entire run.
        let result: Result<Void, Error> = await withTaskCancellationHandler {
            do {
                let owned: Task<Void, Error>
                do {
                    owned = try lease.startPreparation {
                        guard let acquired = payload.take() else {
                            throw NativeLocalConsumerOwnershipError.invalidBinding
                        }
                        try await executeAcquired(acquired, modelID: modelID, execute: execute, tokens: tokens,
                            request: request, requestID: requestID, cacheScope: cacheScope, logprobs: logprobs,
                            usageSignal: usageSignal, donationDemand: donationDemand, loopGuard: loopGuard,
                            onEvent: onEvent)
                    }
                } catch {
                    payload.discard()
                    if let refusal = error as? NativeLocalConsumerOwnershipError, refusal == .closed {
                        try lease.discardUnstartedPreparation()
                        await release.fire()
                    } else {
                        // Invalid duplicate adoption must not release another owner's lease.
                        return .failure(error)
                    }
                    await lease.joinFromOutside()
                    return .failure(error)
                }
                let result = await owned.result
                await lease.joinFromOutside()
                return result
            } catch { return .failure(error) }
        } onCancel: { lease.closeAndCancel() }
        try result.get()
    }

    private static func executeAcquired(
        _ acquired: consuming MultiModelBatchSchedulerEngine.AcquiredModel, modelID: String,
        execute: Execute, tokens: [Int], request: ChatCompletionRequest,
        requestID: String, cacheScope: String?, logprobs: EngineV2LogprobsChannel?,
        usageSignal: EngineV2RequestUsageSignal?, donationDemand: SSDCheckpointDonationDemand?,
        loopGuard: GenerationLoopGuard?, onEvent: @escaping @Sendable (GenerationEvent) async -> Void
    ) async throws {
        do {
            try Task.checkCancellation()
            guard let bridge = acquired.engineV2Bridge else { throw Failure.missingBridge }
            guard bridge.modelId == modelID else { throw Failure.wrongModel }
            try await execute(bridge, tokens, request, requestID, cacheScope, logprobs, usageSignal,
                              donationDemand, loopGuard, onEvent)
            await acquired.releaseToken.fire()
        } catch {
            await acquired.releaseToken.fire()
            throw error
        }
    }

    private static func executeBridge(
        bridge: EngineV2Bridge, tokens: [Int], request: ChatCompletionRequest, requestID: String,
        cacheScope: String?, logprobs: EngineV2LogprobsChannel?, usageSignal: EngineV2RequestUsageSignal?,
        donationDemand: SSDCheckpointDonationDemand?, loopGuard: GenerationLoopGuard?,
        onEvent: @escaping @Sendable (GenerationEvent) async -> Void
    ) async throws {
        let usage = usageSignal ?? EngineV2RequestUsageSignal()
        // A usage signal belongs to one engine request: a continuation has its own.
        let continuationUsage = EngineV2RequestUsageSignal()
        let cancel = RowCancel { await bridge.cancel(requestId: requestID) }
        await withTaskCancellationHandler {
            var stream = await bridge.submitTokenized(
                promptTokens: tokens, request: request, requestId: requestID,
                cacheScope: cacheScope ?? "", cacheEnabled: cacheScope != nil,
                usageSignal: usage, donationDemand: donationDemand, loopGuard: loopGuard)
            if let loopGuard, let exit = loopGuard.exitThinking, !(await bridge.servesDistributedPair) {
                let continuationID = requestID + "-exit"
                let spliced = LoopExitThinkingContinuation.splice(
                    first: stream,
                    cancelFirst: { await bridge.cancel(requestId: requestID) },
                    exit: exit,
                    promptTokens: tokens,
                    outputBudget: bridge.outputTokens(requested: request.max_tokens, promptTokens: tokens.count),
                    submit: { continuationPrompt, budget in
                        guard await bridge.waitForRowRelease(requestId: requestID, within: .seconds(5)) else {
                            throw LoopExitThinkingContinuation.RowNotReleased()
                        }
                        return await bridge.submitTokenized(
                            promptTokens: continuationPrompt, request: request.withMaxTokens(budget),
                            requestId: continuationID,
                            cacheScope: cacheScope ?? "", cacheEnabled: cacheScope != nil,
                            usageSignal: continuationUsage, donationDemand: donationDemand,
                            loopGuard: loopGuard.withoutExit())
                    },
                    cancelContinuation: { await bridge.cancel(requestId: continuationID) },
                    onOutcome: { outcome in
                        if case .continued = outcome {
                            usage.record(matchedStopSequence: continuationUsage.matchedStopSequence)
                        }
                        LoopExitThinkingContinuation.logger.notice(
                            "loop guard ended a thought", metadata: [
                                "request_id": .string(requestID), "outcome": .string(outcome.description)])
                    })
                stream = spliced.events
                cancel.replace(with: spliced.cancel)
            }
            for await event in stream {
                if Task.isCancelled { break }
                // The bridge yields a delta's entries just before its text;
                // they leave on the request's channel in that order.
                if case .logprobs(let entries) = event { logprobs?.append(entries); continue }
                await onEvent(event)
            }
            if Task.isCancelled { await cancel.run() }
            // A terminal event alone does not prove pump/native cleanup has completed.
            await usage.waitForTerminalObservation()
            await continuationUsage.waitForTerminalObservation()
        } onCancel: {
            Task { await cancel.run() }
        }
        try Task.checkCancellation()
    }
}
