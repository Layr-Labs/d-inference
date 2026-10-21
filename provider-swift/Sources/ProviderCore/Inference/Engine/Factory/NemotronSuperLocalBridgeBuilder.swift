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
        /// `maxConcurrentKey` is malformed or above the owner's limit.
        case invalidConcurrency
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
        private var localRequestsAdmitted = 0
        let speculates: Bool
        /// Requests the bridge serves at once; one unless batched decode is on.
        let maximumLocalRequests: Int
        let prefill: NemotronSuperLocalPrefill.Policy
        /// The owner's prefill activation reservation in the shared budget,
        /// held from before the first request until native retirement.
        let prefillLaneBytes: Int
        private let prefillLaneID: String
        /// The engine's resident checkpoint bank budget, reserved in the shared
        /// budget like the lane; zero without text prefix reuse.
        let prefixBankBytes: Int
        private let prefixBankID: String?

        fileprivate init(bridge: EngineV2Bridge, installed: NemotronSuperInstallation.Installed,
                         tokenizer: TokenizerHandle, budget: GlobalKVCacheBudget, contextLength: Int,
                         speculates: Bool, maximumLocalRequests: Int,
                         prefill: NemotronSuperLocalPrefill.Policy, prefillLaneID: String,
                         prefillLaneBytes: Int, prefixBankID: String?, prefixBankBytes: Int) {
            self.bridge = bridge
            self.installed = installed
            self.tokenizer = tokenizer; self.budget = budget; self.contextLength = contextLength
            self.speculates = speculates
            self.maximumLocalRequests = maximumLocalRequests
            self.prefill = prefill
            self.prefillLaneID = prefillLaneID; self.prefillLaneBytes = prefillLaneBytes
            self.prefixBankID = prefixBankID; self.prefixBankBytes = prefixBankBytes
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
                }, reusesTextPrefixes: prefixBankBytes > 0)
                textBinding = binding
                return binding
            }
        }

        /// Admits a local HTTP request, text or image, while fewer than
        /// `maximumLocalRequests` are admitted. Each admission is returned
        /// once by `finishLocalRequest()`, only after its work returned, which
        /// follows native retirement.
        func admitLocalRequest() -> Bool {
            lock.withLock {
                guard localRequestsAdmitted < maximumLocalRequests else { return false }
                localRequestsAdmitted += 1
                return true
            }
        }

        func finishLocalRequest() { lock.withLock { localRequestsAdmitted -= 1 } }

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
                    // Every prefill and checkpoint copy has retired with the
                    // engine; a retained engine above keeps both charged.
                    await budget.release(requestID: prefillLaneID)
                    if let prefixBankID { await budget.release(requestID: prefixBankID) }
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
    /// `mtp` installs opt-in text speculation; nil keeps the target-only owner,
    /// which `NemotronSuperLocalPrefixCache` may give exact text prefix reuse.
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
        let requests = try concurrentRequests(environment: environment, speculates: mtp != nil)
        if let mtp { try NemotronSuperLocalMTP.validate(mtp.setting, requests: requests) }
        let prefixCache = NemotronSuperLocalPrefixCache.config(environment: environment,
            kvBytesCapacity: kvBytesCapacity, speculates: mtp != nil)
        try Task.checkCancellation()
        let (bridge, prefill, laneBytes) = try installed.withNativeSetup(
            construction: construction
        ) { model in
            let language = model.languageModel
            guard let limit = language.calibratedPrefillTokenLimit, limit > 0 else {
                throw Failure.unsupportedSizing
            }
            let prefill = try NemotronSuperLocalPrefill.Policy.resolve(
                environment: environment, prefillLimit: limit)
            // The full-model bound is a measurement of the pinned checkpoint.
            let laneBytes = NemotronSuperLocalPrefill.laneBytes(language,
                chunkTokens: prefill.chunkTokens, measuredBound: installed.isPinnedCheckpoint)
            let workspace = try requestWorkspaceBytes(language)
            let speculation = try mtp.map {
                try NemotronSuperLocalMTP.engine(
                    for: model, head: $0, maximumSequenceLength: sizing.maxContextLength,
                    requests: requests)
            }
            // Several requests share one row-exact [B, 1] decode step (with
            // speculation, one captured [B, 1 + k] verify window); prompts and
            // media still prefill one request per forward. One row is serial.
            let target: any LanguageModel = try speculation?.model
                ?? NemotronSuperRecurrentAdapter(model, maximumDecodeRows: requests, decodeProducts: .rowExact,
                    exactPrefixCheckpoints: prefixCache != nil)
            let draftTokens = mtp?.setting.depth ?? 0
            let bridge = try EngineV2Factory.makeBridge(
                modelId: NemotronSuperLocalBinding.modelID, tokenizer: tokenizer,
                eosTokenIds: eosTokenIDs, defaultMaxTokens: sizing.defaultMaxTokens,
                maxConcurrentRequests: requests,
                // The operator's explicit width; not the posture-gated M5 paged default.
                unqualifiedMaxConcurrentRequests: requests,
                advertisedContextTokens: sizing.maxContextLength,
                runtimePolicyEnvironment: environment,
                kvBytesPerToken: sizing.fp16KVBytesPerToken, kvBudget: kvBudget,
                makeEngine: {
                    try EngineV2Factory.makeProductionBuild(
                        model: target, modelID: NemotronSuperLocalBinding.modelID,
                        tokenizer: tokenizer.inner, kvBytesCapacity: kvBytesCapacity,
                        maxConcurrentRequests: requests, kvBudget: kvBudget,
                        hybridPrefixCache: prefixCache, mtpDrafter: speculation?.assistant,
                        mtpConfig: speculation?.config ?? CBv2MTPConfig(),
                        kvBackend: .contiguous, maxContextLength: sizing.maxContextLength,
                        environment: environment,
                        schedulerPolicy: {
                            prefill.apply(to: &$0, requests: requests, draftTokens: draftTokens)
                        }
                    ).addingSuperRequestWorkspace(workspace)
                })
            return (bridge, prefill, laneBytes)
        }
        // Fixed request bytes and any checkpoint bank are carved from the KV
        // grant before this check; a grant that cannot serve every configured
        // request beside them fails the load.
        if let refusal = await bridge.superGrantRefusal(grantBytes: kvBytesCapacity, requests: requests) {
            try await retireUnpublished(bridge, budget: kvBudget, releasing: [])
            throw refusal
        }
        // One prompt chunk runs per step, so one lane covers every request's
        // prefill. It is reserved before the bridge can admit any request.
        let laneID = NemotronSuperLocalPrefill.laneReservationID()
        let laneReserved =
            laneBytes == 0 ? true : await kvBudget.reserveBytes(requestID: laneID, bytes: UInt64(laneBytes))
        guard laneReserved else {
            try await retireUnpublished(bridge, budget: kvBudget, releasing: [])
            throw NemotronSuperLocalPrefill.Failure.laneRefused
        }
        // The bank keeps checkpoints between requests, beyond any request's
        // charge: its whole budget is reserved before the first request and
        // held until native retirement, like the lane.
        var bank: (id: String, bytes: Int)?
        if let prefixCache {
            let bytes = await bridge.superPrefixBankBytes
            guard bytes == prefixCache.maximumBytes else {
                try await retireUnpublished(bridge, budget: kvBudget, releasing: [laneID])
                throw NemotronSuperLocalPrefixCache.Failure.unavailable
            }
            let id = NemotronSuperLocalPrefixCache.bankReservationID()
            guard await kvBudget.reserveBytes(requestID: id, bytes: UInt64(bytes)) else {
                try await retireUnpublished(bridge, budget: kvBudget, releasing: [laneID])
                throw NemotronSuperLocalPrefixCache.Failure.bankRefused
            }
            bank = (id, bytes)
        }
        // Without speculation the dedicated image binding uses causal
        // embeddings and no checkpoint identity; execution stays contiguous.
        return Owner(bridge: bridge, installed: installed, tokenizer: tokenizer,
                     budget: kvBudget, contextLength: sizing.maxContextLength,
                     speculates: mtp != nil, maximumLocalRequests: requests,
                     prefill: prefill, prefillLaneID: laneID, prefillLaneBytes: laneBytes,
                     prefixBankID: bank?.id, prefixBankBytes: bank?.bytes ?? 0)
    }

    /// A bridge that never reached an owner: shut it down and, only once the
    /// engine has retired, release the owner-level reservations already taken.
    private static func retireUnpublished(_ bridge: EngineV2Bridge, budget: GlobalKVCacheBudget,
                                          releasing ids: [String]) async throws {
        await bridge.shutdown()
        guard await bridge.superLocalEngineRetired else { throw Failure.retirementIncomplete }
        for id in ids { await budget.release(requestID: id) }
    }
}

private extension EngineV2Bridge {
    var superLocalEngineRetired: Bool { ownedEngine == nil }
    /// The constructed engine's checkpoint bank budget; zero without a bank.
    var superPrefixBankBytes: Int {
        (ownedEngine as? EngineV2)?.hybridPrefixCache?.config.maximumBytes ?? 0
    }
}
