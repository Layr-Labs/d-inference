// Copyright © 2026 Eigen Labs.

import Foundation

/// Experimental, unregistered local qualification boundary. The acquisition closure MUST
/// come from the existing atomic provider acquire path after its container/bridge builder
/// has gained a qualified Super adapter. Installing SDK weights alone cannot provide it.
/// This type neither loads weights nor manufactures admission, trust, or registry entries.
actor NemotronSuperLocalBinding {
    /// The qualification hook's model id; a managed slot serves its registry id.
    static let modelID = "nvidia/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-NVFP4"
    enum Failure: Error, Equatable {
        case drained, wrongModel, unsupportedCapability, invalidTokens, missingBridge
    }
    typealias Acquire = @Sendable (String) async throws -> MultiModelBatchSchedulerEngine.AcquiredModel
    /// Internal fixture seam; production uses the bridge's real retirement barrier
    /// below. The `String?` is the request's prefix-cache scope (nil: no reuse).
    typealias Execute = @Sendable (EngineV2Bridge, [Int], ChatCompletionRequest, String, String?,
        @escaping @Sendable (GenerationEvent) async -> Void) async throws -> Void

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
        self.execute = { bridge, tokens, request, requestID, cacheScope, onEvent in
            try await Self.executeBridge(bridge: bridge, tokens: tokens, request: request,
                requestID: requestID, cacheScope: reusesTextPrefixes ? cacheScope : nil, onEvent: onEvent)
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
    /// nil disables reuse for this request).
    func run(request: ChatCompletionRequest, promptTokens: [Int],
             hasMedia: Bool = false, cacheScope: String? = "",
             onEvent: @escaping @Sendable (GenerationEvent) async -> Void) async throws {
        guard !draining else { throw Failure.drained }
        guard request.model == modelID else { throw Failure.wrongModel }
        guard !hasMedia, !promptTokens.contains(18), request.tools == nil, request.tool_choice == nil,
              request.response_format == nil, request.logprobs != true,
              request.top_logprobs == nil, request.prompt_cache_key == nil
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
                request: request, requestID: id.uuidString, cacheScope: cacheScope, onEvent: onEvent)
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
        requestID: String, cacheScope: String?, onEvent: @escaping @Sendable (GenerationEvent) async -> Void
    ) async throws {
        guard let lease = acquired.nativeConsumerLease else {
            return try await executeAcquired(acquired, modelID: modelID, execute: execute, tokens: tokens,
                request: request, requestID: requestID, cacheScope: cacheScope, onEvent: onEvent)
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
                            request: request, requestID: requestID, cacheScope: cacheScope, onEvent: onEvent)
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
        requestID: String, cacheScope: String?, onEvent: @escaping @Sendable (GenerationEvent) async -> Void
    ) async throws {
        do {
            try Task.checkCancellation()
            guard let bridge = acquired.engineV2Bridge else { throw Failure.missingBridge }
            guard bridge.modelId == modelID else { throw Failure.wrongModel }
            try await execute(bridge, tokens, request, requestID, cacheScope, onEvent)
            await acquired.releaseToken.fire()
        } catch {
            await acquired.releaseToken.fire()
            throw error
        }
    }

    private static func executeBridge(
        bridge: EngineV2Bridge, tokens: [Int], request: ChatCompletionRequest, requestID: String,
        cacheScope: String?, onEvent: @escaping @Sendable (GenerationEvent) async -> Void
    ) async throws {
        let usage = EngineV2RequestUsageSignal()
        await withTaskCancellationHandler {
            let stream = await bridge.submitTokenized(
                promptTokens: tokens, request: request, requestId: requestID,
                cacheScope: cacheScope ?? "", cacheEnabled: cacheScope != nil, usageSignal: usage)
            for await event in stream {
                if Task.isCancelled { break }
                await onEvent(event)
            }
            if Task.isCancelled { await bridge.cancel(requestId: requestID) }
            // A terminal event alone does not prove pump/native cleanup has completed.
            await usage.waitForTerminalObservation()
        } onCancel: {
            Task { await bridge.cancel(requestId: requestID) }
        }
        try Task.checkCancellation()
    }
}
