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
    enum Failure: Error {
        case unloaded, loadAdmissionLost, unsupportedSizing, retirementIncomplete
        /// Text speculation is installed; its target refuses media embeddings.
        case mediaWithSpeculation
    }

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
        private var textBinding: NemotronSuperLocalBinding?
        private var imageFaults: [(NativeConstructionScope, WholeMacUnboundedActivity)] = []
        private var quarantine: Owner?
        private var localRequestAdmitted = false
        let speculates: Bool

        fileprivate init(bridge: EngineV2Bridge, installed: NemotronSuperInstallation.Installed,
                         tokenizer: TokenizerHandle, budget: GlobalKVCacheBudget, contextLength: Int,
                         speculates: Bool) {
            self.bridge = bridge
            self.installed = installed
            self.tokenizer = tokenizer; self.budget = budget; self.contextLength = contextLength
            self.speculates = speculates
        }

        var imageServiceBudget: WholeMacServiceBudget { budget.serviceBudget }
        var hasRetainedImageFault: Bool { lock.withLock { !imageFaults.isEmpty } }

        /// Dedicated local owner only; no external acquisition closure can bind
        /// another slot's installation, tokenizer, lease or bridge by model name.
        func localImageBinding() throws -> NemotronSuperLocalImageBinding {
            guard !speculates else { throw Failure.mediaWithSpeculation }
            return try lock.withLock {
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

        /// The owner's single text binding on its own bridge and tokenizer. No
        /// registry lease or slot is manufactured; acquisition refuses once the
        /// owner closes or retains a fault. `closeAfterDrain` drains it first.
        func localTextBinding() throws -> NemotronSuperLocalBinding {
            try lock.withLock {
                guard closing == nil, imageFaults.isEmpty, installed != nil else {
                    throw Failure.retirementIncomplete
                }
                if let textBinding { return textBinding }
                let bridge = self.bridge, tokenizer = self.tokenizer
                let binding = NemotronSuperLocalBinding(acquire: { [weak self] model in
                    guard let self, self.acceptsLocalWork else { throw Failure.retirementIncomplete }
                    return .init(tokenizer: tokenizer,
                        releaseToken: OneShotRelease(release: { _ in }, modelId: model),
                        modelType: "nemotron_h_omni", engineV2Bridge: bridge)
                })
                textBinding = binding
                return binding
            }
        }

        /// The bridge serves one request: admits one local HTTP request, text
        /// or image, until `finishLocalRequest()`. Callers finish only after
        /// the admitted work returned, which follows native retirement.
        func admitLocalRequest() -> Bool {
            lock.withLock {
                guard !localRequestAdmitted else { return false }
                localRequestAdmitted = true
                return true
            }
        }

        func finishLocalRequest() { lock.withLock { localRequestAdmitted = false } }

        private var acceptsLocalWork: Bool {
            lock.withLock { closing == nil && imageFaults.isEmpty && installed != nil }
        }

        /// Uses this loaded owner's tokenizer and the pinned literal template.
        /// Input counts come from the admitted image processor, in message order.
        func localImagePrompt(body: Data, templateBytes: Data, featureCounts: [Int]) throws -> [Int] {
            guard !speculates else { throw Failure.mediaWithSpeculation }
            return try lock.withLock {
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
                // Context overflow keeps the image path's capacity status.
                do {
                    return try NemotronSuperPromptContract.imagePrompt(messages: request.messages,
                        body: body, templateBytes: templateBytes, tokenizer: tokenizer.inner,
                        featureCounts: featureCounts, contextLength: contextLength)
                } catch NemotronSuperPromptContract.Failure.contextExceeded {
                    throw NemotronSuperLocalImageBinding.Failure.capacity
                } catch NemotronSuperPromptContract.Failure.unsupportedMedia {
                    throw NemotronSuperLocalImageBinding.Failure.invalidInput
                }
            }
        }

        func makeLocalImageInput(promptTokens: [Int], pixels: [[Float]], widths: [Int], heights: [Int],
            construction: NativeConstructionScope
        ) throws -> NemotronSuperLocalImageBinding.Input {
            guard !speculates else { throw Failure.mediaWithSpeculation }
            return try lock.withLock {
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
            guard !speculates else { throw Failure.mediaWithSpeculation }
            return try lock.withLock {
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

        /// Slot owner must first close acquisition. This drains the owner's text
        /// and image bindings; a retained native engine is a fault, never
        /// evidence permitting a refund.
        func closeAfterDrain() async throws {
            let closing = lock.withLock { () -> Task<Void, Error> in
                if let closing = self.closing { return closing }
                let images = imageBinding
                let text = textBinding
                let task = Task { [self] in
                    await text?.drain()
                    try await images?.drain()
                    guard !hasRetainedImageFault else { throw Failure.retirementIncomplete }
                    await bridge.shutdown()
                    guard await bridge.superLocalEngineRetired else { throw Failure.retirementIncomplete }
                    lock.withLock {
                        installed?.closeAfterRetirement()
                        installed = nil
                        imageBinding = nil
                        textBinding = nil
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
    /// `mtp` installs opt-in text speculation; nil keeps the target-only owner.
    static func make(
        installed: NemotronSuperInstallation.Installed,
        tokenizer: TokenizerHandle, eosTokenIDs: Set<Int>,
        sizing: SlotSizingSnapshot, kvBytesCapacity: Int,
        kvBudget: GlobalKVCacheBudget, loadLease: PendingModelLoadLease,
        construction: NativeConstructionScope, mtp: NemotronSuperLocalMTP.Head? = nil,
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
            let language = model.languageModel
            guard let limit = language.calibratedPrefillTokenLimit, limit > 0 else {
                throw Failure.unsupportedSizing
            }
            // The graph path's explicit ModelOpt arrays for the largest chunk the
            // engine may run (prefill, decode and verify rows are all at most
            // `limit`). The eager reference keeps its own bounded tiles.
            let prefillWorkspace = language.modelOptGraphPrefillWorkspaceBytes(tokens: limit) ?? 0
            let speculation = try mtp.map {
                try NemotronSuperLocalMTP.engine(
                    for: model, head: $0, maximumSequenceLength: sizing.maxContextLength)
            }
            let target: any LanguageModel = speculation?.model ?? NemotronSuperRecurrentAdapter(model)
            return try EngineV2Factory.makeBridge(
                modelId: NemotronSuperLocalBinding.modelID, tokenizer: tokenizer,
                eosTokenIds: eosTokenIDs, defaultMaxTokens: sizing.defaultMaxTokens,
                maxConcurrentRequests: 1, advertisedContextTokens: sizing.maxContextLength,
                runtimePolicyEnvironment: environment,
                kvBytesPerToken: sizing.fp16KVBytesPerToken, kvBudget: kvBudget,
                makeEngine: {
                    try EngineV2Factory.makeProductionBuild(
                        model: target, modelID: NemotronSuperLocalBinding.modelID,
                        tokenizer: tokenizer.inner, kvBytesCapacity: kvBytesCapacity,
                        maxConcurrentRequests: 1, kvBudget: kvBudget,
                        mtpDrafter: speculation?.assistant,
                        mtpConfig: speculation?.config ?? CBv2MTPConfig(),
                        kvBackend: .contiguous, maxContextLength: sizing.maxContextLength,
                        environment: environment
                    ).addingFixedRequestBytes(prefillWorkspace)
                })
        }
        // The prefill workspace is carved from the KV grant with each request's
        // charge; a grant that cannot serve one request fails the load.
        do { try await bridge.requireServiceableOrdinaryGrant() } catch {
            await bridge.shutdown()
            guard await bridge.superLocalEngineRetired else { throw Failure.retirementIncomplete }
            throw Failure.unsupportedSizing
        }
        // Prefix stores remain absent. Without speculation the dedicated image
        // binding uses causal embeddings; recurrent execution stays serial/contiguous.
        return Owner(bridge: bridge, installed: installed, tokenizer: tokenizer,
                     budget: kvBudget, contextLength: sizing.maxContextLength,
                     speculates: mtp != nil)
    }
}

private extension EngineV2Bridge {
    var superLocalEngineRetired: Bool { ownedEngine == nil }
}

private extension EngineV2Factory.ProductionBuild {
    /// The same build with `bytes` more fixed workspace in every request's
    /// shared-budget reservation, admitted before submission and held until
    /// the request retires.
    func addingFixedRequestBytes(_ bytes: Int) throws -> Self {
        let (total, overflow) = fixedRequestBytes.addingReportingOverflow(bytes)
        guard bytes >= 0, !overflow, total < Int.max else {
            throw NemotronSuperLocalBridgeBuilder.Failure.unsupportedSizing
        }
        return .init(engine: engine, fixedRequestBytes: total, kvBackendKind: kvBackendKind,
            kvBackendFallbackReason: kvBackendFallbackReason, pagedPoolDType: pagedPoolDType,
            usesProcessMemoryOwner: usesProcessMemoryOwner,
            mtpAdmissionResolution: mtpAdmissionResolution,
            legacyMTPBytesPerToken: legacyMTPBytesPerToken,
            effectiveMaxConcurrentRequests: effectiveMaxConcurrentRequests,
            kvQuantization: kvQuantization, kvCheckpointQuantization: kvCheckpointQuantization,
            admissionWatermarkFraction: admissionWatermarkFraction)
    }
}
