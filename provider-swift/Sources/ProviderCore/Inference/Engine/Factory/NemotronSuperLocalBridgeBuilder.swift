// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM

/// Unregistered assembly over the actual installed Super language and image towers.
/// The existing owner still performs identity verification, slot publication, LOAD
/// admission and atomic request acquisition. This builder does none of those jobs.
enum NemotronSuperLocalBridgeBuilder {
    enum Failure: Error { case unloaded, loadAdmissionLost, unsupportedSizing, retirementIncomplete }

    /// Must be retained by the slot owner while its bridge is reachable. Transfer
    /// the installation here; callers must not keep mutable model aliases or close
    /// the installation independently. An abandoned owner never refunds residency.
    final class Owner: @unchecked Sendable {
        let bridge: EngineV2Bridge
        private let lock = NSLock()
        private var installed: NemotronSuperInstallation.Installed?
        private var closing: Task<Void, Error>?
        private let tokenizer: TokenizerHandle
        private let budget: GlobalKVCacheBudget
        private let contextLength: Int
        private var imageBinding: NemotronSuperLocalImageBinding?
        private var imageFaults: [(NativeConstructionScope, WholeMacUnboundedActivity)] = []
        private var quarantine: Owner?

        fileprivate init(bridge: EngineV2Bridge, installed: NemotronSuperInstallation.Installed,
                         tokenizer: TokenizerHandle, budget: GlobalKVCacheBudget, contextLength: Int) {
            self.bridge = bridge
            self.installed = installed
            self.tokenizer = tokenizer; self.budget = budget; self.contextLength = contextLength
        }

        var imageServiceBudget: WholeMacServiceBudget { budget.serviceBudget }
        var hasRetainedImageFault: Bool { lock.withLock { !imageFaults.isEmpty } }

        /// Dedicated local owner only; no external acquisition closure can bind
        /// another slot's installation, tokenizer, lease or bridge by model name.
        func localImageBinding() throws -> NemotronSuperLocalImageBinding {
            try lock.withLock {
                guard closing == nil, imageFaults.isEmpty, installed != nil else {
                    throw Failure.retirementIncomplete
                }
                if let imageBinding { return imageBinding }
                let binding = NemotronSuperLocalImageBinding(owner: self,
                    budget: budget, contextLength: contextLength)
                imageBinding = binding
                return binding
            }
        }

        /// Uses this loaded owner's tokenizer and the pinned literal template.
        /// Input counts come from the admitted image processor, in message order.
        func localImagePrompt(body: Data, templateBytes: Data, featureCounts: [Int]) throws -> [Int] {
            try lock.withLock {
                guard closing == nil, imageFaults.isEmpty, installed != nil else {
                    throw Failure.retirementIncomplete
                }
                let request = try ProviderLoop.decodeOpenAIRequest(body)
                guard request.model == NemotronSuperLocalBinding.modelID,
                    request.tools == nil, request.toolChoice == nil, request.responseFormat == nil,
                    !featureCounts.isEmpty, featureCounts.allSatisfy({ $0 > 0 && $0 <= contextLength })
                else { throw NemotronSuperLocalImageBinding.Failure.invalidInput }
                var imageCount = 0
                for message in request.messages {
                    if case .parts(let parts) = message.content {
                        for part in parts {
                            if case .imageURL = part { imageCount += 1 }
                        }
                    }
                }
                guard imageCount == featureCounts.count else {
                    throw NemotronSuperLocalImageBinding.Failure.invalidInput
                }
                let template = try NemotronSuperPromptContract.verifiedTemplate(templateBytes)
                let raw = try tokenizer.inner.applyChatTemplate(
                    messages: NemotronSuperPromptContract.messages(request.messages),
                    chatTemplate: template, tools: nil,
                    additionalContext: NemotronSuperPromptContract.additionalContext(body: body))
                guard raw.filter({ $0 == 18 }).count == featureCounts.count else {
                    throw NemotronSuperLocalImageBinding.Failure.invalidInput
                }
                var result: [Int] = [], index = 0
                for token in raw {
                    let count = token == 18 ? featureCounts[index] : 1
                    guard count <= contextLength - result.count else {
                        throw NemotronSuperLocalImageBinding.Failure.capacity
                    }
                    result.append(contentsOf: repeatElement(token, count: count))
                    if token == 18 { index += 1 }
                }
                return result
            }
        }

        func makeLocalImageInput(promptTokens: [Int], pixels: [[Float]], widths: [Int], heights: [Int],
            construction: NativeConstructionScope
        ) throws -> NemotronSuperLocalImageBinding.Input {
            try lock.withLock {
                guard closing == nil, imageFaults.isEmpty, let installed else {
                    throw Failure.retirementIncomplete
                }
                return .init(promptTokens: promptTokens,
                    normalizedImages: try NemotronSuperVisionPreparation.makeNormalizedImages(
                        installed: installed, pixels: pixels, widths: widths, heights: heights,
                        construction: construction))
            }
        }

        func prepareLocalImage(_ input: NemotronSuperLocalImageBinding.Input,
            maximumFeatureBytes: Int, construction: NativeConstructionScope
        ) throws -> EngineV2VisionPrefill.PreparedSubmission {
            try lock.withLock {
                guard closing == nil, imageFaults.isEmpty, let installed else {
                    throw Failure.retirementIncomplete
                }
                return NemotronSuperVisionSubmission.make(try NemotronSuperVisionPreparation.prepare(
                    installed: installed, prompt: input.promptTokens.map(Int32.init),
                    normalizedImages: input.normalizedImages, maximumFeatureBytes: maximumFeatureBytes,
                    construction: construction))
            }
        }

        func quarantineLocalImage(construction: NativeConstructionScope, activity: WholeMacUnboundedActivity) {
            lock.withLock {
                imageFaults.append((construction, activity))
                quarantine = self
            }
        }

        /// Slot owner must first close acquisition and drain local bindings. A
        /// retained native engine is a fault, never evidence permitting a refund.
        func closeAfterDrain() async throws {
            let closing = lock.withLock { () -> Task<Void, Error> in
                if let closing = self.closing { return closing }
                let images = imageBinding
                let task = Task { [self] in
                    try await images?.drain()
                    guard !hasRetainedImageFault else { throw Failure.retirementIncomplete }
                    await bridge.shutdown()
                    guard await bridge.superLocalEngineRetired else { throw Failure.retirementIncomplete }
                    lock.withLock {
                        installed?.closeAfterRetirement()
                        installed = nil
                        imageBinding = nil
                    }
                }
                self.closing = task
                return task
            }
            try await closing.value
        }
    }

    /// `loadLease` is the real existing pending LOAD claim, never a new permit.
    /// KV grant/sizing must come from the existing slot re-slice and loaded sizing
    /// path. Native setup/probes run inside the SDK construction scope. Caller
    /// must retain a faulted scope and its charged installation until restart.
    static func make(
        installed: NemotronSuperInstallation.Installed,
        tokenizer: TokenizerHandle, eosTokenIDs: Set<Int>,
        sizing: SlotSizingSnapshot, kvBytesCapacity: Int,
        kvBudget: GlobalKVCacheBudget, loadLease: PendingModelLoadLease,
        construction: NativeConstructionScope,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> Owner {
        guard installed.receipt.payloadBytes > 0,
            await kvBudget.recheckPendingLoad(loadLease,
                minimumWeightBytes: UInt64(installed.receipt.payloadBytes),
                minimumKVBytes: UInt64(max(0, kvBytesCapacity)))
        else { throw Failure.loadAdmissionLost }
        guard sizing.weightsBytes >= installed.receipt.payloadBytes,
              sizing.fp16KVBytesPerToken > 0, kvBytesCapacity > 0,
              sizing.maxContextLength > 0, sizing.maxContextLength <= 16384,
              sizing.defaultMaxTokens > 0, sizing.defaultMaxTokens <= sizing.maxContextLength
        else { throw Failure.unsupportedSizing }
        try Task.checkCancellation()
        let bridge = try installed.withNativeSetup(construction: construction) { model in
            guard let limit = model.languageModel.calibratedPrefillTokenLimit, limit > 0 else {
                throw Failure.unsupportedSizing
            }
            let adapter = NemotronSuperRecurrentAdapter(model)
            return try EngineV2Factory.makeBridge(
                modelId: NemotronSuperLocalBinding.modelID, tokenizer: tokenizer,
                eosTokenIds: eosTokenIDs, defaultMaxTokens: sizing.defaultMaxTokens,
                maxConcurrentRequests: 1, advertisedContextTokens: sizing.maxContextLength,
                runtimePolicyEnvironment: environment,
                kvBytesPerToken: sizing.fp16KVBytesPerToken, kvBudget: kvBudget,
                makeEngine: {
                    try EngineV2Factory.makeProductionBuild(
                        model: adapter, modelID: NemotronSuperLocalBinding.modelID,
                        tokenizer: tokenizer.inner, kvBytesCapacity: kvBytesCapacity,
                        maxConcurrentRequests: 1, kvBudget: kvBudget,
                        kvBackend: .contiguous, maxContextLength: sizing.maxContextLength,
                        environment: environment)
                })
        }
        // MTP and prefix stores remain absent. The dedicated image binding uses
        // causal embeddings; initial recurrent execution stays serial/contiguous.
        return Owner(bridge: bridge, installed: installed, tokenizer: tokenizer,
                     budget: kvBudget, contextLength: sizing.maxContextLength)
    }
}

private extension EngineV2Bridge {
    var superLocalEngineRetired: Bool { ownedEngine == nil }
}
