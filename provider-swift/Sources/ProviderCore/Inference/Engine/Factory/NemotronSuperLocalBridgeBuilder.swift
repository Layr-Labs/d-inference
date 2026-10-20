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
        /// `maxConcurrentKey` is malformed or above the owner's limit.
        case invalidConcurrency
    }

    /// Must be retained by the slot owner while its bridge is reachable. Transfer
    /// the installation here; callers must not keep mutable model aliases or close
    /// the installation independently. An abandoned owner never refunds residency.
    final class Owner: @unchecked Sendable {
        let bridge: EngineV2Bridge
        /// The one model id every route of this owner serves.
        let modelID: String
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
        /// budget like the lane; zero without prefix reuse.
        let prefixBankBytes: Int
        private let prefixBankID: String?
        /// Paged storage only: every request's decode-row workspace, reserved
        /// in the shared budget like the lane; zero on contiguous storage,
        /// where the bridge reserves it with each request.
        let decodeRowsBytes: Int
        private let decodeRowsID: String?
        /// Speculating owners: the assistant's round work and the captured
        /// verify windows, sized once per engine (`ownerBytes` of the engine's
        /// MTP admission) and reserved in the shared budget like the lane.
        let mtpRoundBytes: Int
        private let mtpRoundID: String?

        fileprivate init(bridge: EngineV2Bridge, modelID: String, installed: NemotronSuperInstallation.Installed,
                         tokenizer: TokenizerHandle, budget: GlobalKVCacheBudget, contextLength: Int,
                         speculates: Bool, maximumLocalRequests: Int,
                         prefill: NemotronSuperLocalPrefill.Policy, prefillLaneID: String,
                         prefillLaneBytes: Int, prefixBankID: String?, prefixBankBytes: Int,
                         decodeRowsID: String?, decodeRowsBytes: Int,
                         mtpRoundID: String?, mtpRoundBytes: Int) {
            self.bridge = bridge
            self.modelID = modelID
            self.installed = installed
            self.tokenizer = tokenizer; self.budget = budget; self.contextLength = contextLength
            self.speculates = speculates
            self.maximumLocalRequests = maximumLocalRequests
            self.prefill = prefill
            self.prefillLaneID = prefillLaneID; self.prefillLaneBytes = prefillLaneBytes
            self.prefixBankID = prefixBankID; self.prefixBankBytes = prefixBankBytes
            self.decodeRowsID = decodeRowsID; self.decodeRowsBytes = decodeRowsBytes
            self.mtpRoundID = mtpRoundID; self.mtpRoundBytes = mtpRoundBytes
        }

        var imageServiceBudget: WholeMacServiceBudget { budget.serviceBudget }
        var hasRetainedImageFault: Bool { lock.withLock { !imageFaults.isEmpty } }

        /// Dedicated local owner only; no external acquisition closure can bind
        /// another slot's installation, tokenizer, lease or bridge by model name.
        func localImageBinding() throws -> NemotronSuperLocalImageBinding {
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
                let binding = NemotronSuperLocalBinding(modelID: modelID, acquire: { [weak self] model in
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
            return try lock.withLock {
                guard closing == nil, imageFaults.isEmpty, installed != nil else {
                    throw Failure.retirementIncomplete
                }
                let request = try ProviderLoop.decodeOpenAIRequest(body)
                guard request.model == modelID,
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
            return try lock.withLock {
                guard closing == nil, imageFaults.isEmpty, let installed else {
                    throw Failure.retirementIncomplete
                }
                let prepared = try NemotronSuperVisionPreparation.prepare(
                    installed: installed, prompt: input.promptTokens.map(Int32.init),
                    normalizedImages: input.normalizedImages, maximumFeatureBytes: maximumFeatureBytes,
                    construction: construction)
                // The features are evaluated; a non-finite value would decode
                // as garbage, so the request fails instead of streaming it.
                for feature in prepared.features where !all(isFinite(feature)).item(Bool.self) {
                    throw NemotronSuperLocalImageBinding.Failure.invalidFeatures
                }
                return NemotronSuperVisionSubmission.make(prepared)
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
                    if let decodeRowsID { await budget.release(requestID: decodeRowsID) }
                    if let mtpRoundID { await budget.release(requestID: mtpRoundID) }
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

    /// The owner-level reservations a pinned load's LOAD claim also holds, so
    /// one claim before allocation covers everything the loaded owner keeps:
    /// the prefill lane at the measured whole-chunk bound, a speculating
    /// owner's round work (`NemotronSuperServingPolicy.speculativeOwnerBoundBytes`)
    /// and the default (or operator) prefix bank on either KV backend.
    struct OwnerShares: Equatable, Sendable {
        let lane: Int
        var round = 0
        let bank: Int

        /// Every share; nil when they overflow.
        var total: Int? {
            let (partial, first) = lane.addingReportingOverflow(round)
            let (sum, second) = partial.addingReportingOverflow(bank)
            return first || second ? nil : sum
        }
    }

    /// `OwnerShares` of the pinned checkpoint's owner under this grant and
    /// runtime policy at `contextTokens`, computed as `make` computes the lane
    /// and the bank and as the serving policy bounds the round. A chunk key
    /// outside 1...`maximumContextTokens` counts no lane share (the builder
    /// refuses the key itself).
    static func pinnedOwnerShares(environment: [String: String], kvBytesCapacity: Int, speculates: Bool,
                                  contextTokens: Int = NemotronSuperServingPolicy.contextTokens,
                                  physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) throws
        -> OwnerShares {
        let lane = NemotronSuperLocalPrefill.requestedChunkTokens(environment: environment)
            .map(NemotronSuperLocalPrefill.pinnedLaneBytes) ?? 0
        let requests = try concurrentRequests(environment: environment, speculates: speculates)
        let bank = NemotronSuperLocalPrefixCache.config(environment: environment,
            kvBytesCapacity: kvBytesCapacity, requests: requests, speculates: speculates,
            physicalBytes: physicalBytes)?.maximumBytes ?? 0
        let round = speculates
            ? NemotronSuperServingPolicy.speculativeOwnerBoundBytes(requests: requests,
                environment: environment, contextTokens: contextTokens)
            : 0
        guard round < Int.max else { throw Failure.unsupportedSizing }
        return OwnerShares(lane: lane, round: round, bank: bank)
    }

    /// `loadLease` is the real existing pending LOAD claim, never a new permit;
    /// it must hold at least `admissionKVBytes` (nil: the whole grant) of KV
    /// headroom. With `leaseShares` the caller has already handed the resident
    /// installation's share of the claim over to live usage and the lease holds
    /// exactly those owner shares beside its KV floor; each share is released
    /// right before its own reservation, so no byte is counted twice. Without
    /// them the lease must still cover the installation's payload, and the lane
    /// and bank are admitted on their own. KV grant/sizing must come from the existing slot re-slice and
    /// loaded sizing path. Native setup/probes run inside the SDK construction
    /// scope. Caller must retain a faulted scope and its charged installation
    /// until restart. `mtp` installs speculation for text requests; image
    /// requests on that owner stay target-only. nil keeps the target-only
    /// owner. Either owner may have `NemotronSuperLocalPrefixCache`'s exact
    /// prefix reuse.
    static func make(
        installed: NemotronSuperInstallation.Installed,
        tokenizer: TokenizerHandle, eosTokenIDs: Set<Int>,
        sizing: SlotSizingSnapshot, kvBytesCapacity: Int, admissionKVBytes: Int? = nil,
        kvBudget: GlobalKVCacheBudget, loadLease: PendingModelLoadLease,
        construction: NativeConstructionScope, mtp: NemotronSuperLocalMTP.Head? = nil,
        modelID: String = NemotronSuperLocalBinding.modelID,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        leaseShares: OwnerShares? = nil,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> Owner {
        let leaseWeightBytes = leaseShares.map { $0.total ?? -1 } ?? installed.receipt.payloadBytes
        guard installed.receipt.payloadBytes > 0, leaseWeightBytes >= 0,
            await kvBudget.recheckPendingLoad(loadLease,
                minimumWeightBytes: UInt64(leaseWeightBytes),
                minimumKVBytes: UInt64(max(0, admissionKVBytes ?? kvBytesCapacity)))
        else { throw Failure.loadAdmissionLost }
        guard sizing.weightsBytes >= installed.receipt.payloadBytes,
              sizing.fp16KVBytesPerToken > 0, kvBytesCapacity > 0,
              sizing.maxContextLength > 0,
              sizing.maxContextLength <= NemotronSuperServingPolicy.maximumContextTokens,
              sizing.defaultMaxTokens > 0, sizing.defaultMaxTokens <= sizing.maxContextLength
        else { throw Failure.unsupportedSizing }
        let requests = try concurrentRequests(environment: environment, speculates: mtp != nil)
        if let mtp { try NemotronSuperLocalMTP.validate(mtp.setting, requests: requests) }
        let prefixCache = NemotronSuperLocalPrefixCache.config(environment: environment,
            kvBytesCapacity: kvBytesCapacity, requests: requests, speculates: mtp != nil,
            pinned: installed.isPinnedCheckpoint, physicalBytes: physicalBytes, modelID: modelID)
        let kvBackend = try NemotronSuperLocalKVBackend.resolve(environment: environment)
        try Task.checkCancellation()
        let (bridge, prefill, laneBytes, workspace) = try installed.withNativeSetup(
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
                    requests: requests, exactPrefixCheckpoints: prefixCache != nil)
            }
            // Several requests share one row-exact [B, 1] decode step (with
            // speculation, one captured [B, 1 + k] verify window); prompts and
            // media still prefill one request per forward. One row is serial.
            let target: any LanguageModel = try speculation?.model
                ?? NemotronSuperRecurrentAdapter(model, maximumDecodeRows: requests, decodeProducts: .rowExact,
                    exactPrefixCheckpoints: prefixCache != nil)
            let draftTokens = mtp?.setting.depth ?? 0
            let bridge = try EngineV2Factory.makeBridge(
                modelId: modelID, tokenizer: tokenizer,
                eosTokenIds: eosTokenIDs, defaultMaxTokens: sizing.defaultMaxTokens,
                maxConcurrentRequests: requests,
                // The operator's explicit width; not the posture-gated M5 paged default.
                unqualifiedMaxConcurrentRequests: requests,
                advertisedContextTokens: sizing.maxContextLength,
                runtimePolicyEnvironment: environment,
                kvBytesPerToken: sizing.fp16KVBytesPerToken, kvBudget: kvBudget,
                makeEngine: {
                    try EngineV2Factory.makeProductionBuild(
                        model: target, modelID: modelID,
                        tokenizer: tokenizer.inner, kvBytesCapacity: kvBytesCapacity,
                        maxConcurrentRequests: requests, kvBudget: kvBudget,
                        hybridPrefixCache: prefixCache, mtpDrafter: speculation?.assistant,
                        mtpConfig: speculation?.config ?? CBv2MTPConfig(),
                        kvBackend: kvBackend, maxContextLength: sizing.maxContextLength,
                        environment: environment,
                        schedulerPolicy: {
                            prefill.apply(to: &$0, requests: requests, draftTokens: draftTokens)
                        }
                    ).addingSuperRequestWorkspace(workspace)
                })
            return (bridge, prefill, laneBytes, workspace)
        }
        // Fixed request bytes and any checkpoint bank are carved from the KV
        // grant before this check; a grant that cannot serve every configured
        // request beside them fails the load.
        if let refusal = await bridge.superGrantRefusal(grantBytes: kvBytesCapacity, requests: requests) {
            try await retireUnpublished(bridge, budget: kvBudget, releasing: [])
            throw refusal
        }
        // One prompt chunk runs per step, so one lane covers every request's
        // prefill. It is reserved before the bridge can admit any request,
        // taking over the lease's lane share (any excess is admitted here).
        if let leaseShares {
            guard await kvBudget.reducePendingLoad(loadLease,
                remainingWeightBytes: UInt64(leaseShares.round + leaseShares.bank))
            else {
                try await retireUnpublished(bridge, budget: kvBudget, releasing: [])
                throw Failure.loadAdmissionLost
            }
        }
        let laneID = NemotronSuperLocalPrefill.laneReservationID()
        let laneReserved =
            laneBytes == 0 ? true : await kvBudget.reserveBytes(requestID: laneID, bytes: UInt64(laneBytes))
        guard laneReserved else {
            try await retireUnpublished(bridge, budget: kvBudget, releasing: [])
            throw NemotronSuperLocalPrefill.Failure.laneRefused
        }
        // Paged storage is charged by the engine's process-memory owner and
        // the bridge reserves no request bytes; reserve the decode rows here.
        let built = await bridge.kvBackendKind
        let rowsBytes = try? NemotronSuperLocalKVBackend.decodeRowsBytes(
            selection: built == .paged ? .paged : .contiguous, requests: requests,
            rowBytes: workspace)
        var rows: (id: String, bytes: Int)?
        if rowsBytes != 0 {
            let id = NemotronSuperLocalKVBackend.decodeRowsReservationID()
            guard let rowsBytes,
                await kvBudget.reserveBytes(requestID: id, bytes: UInt64(rowsBytes))
            else {
                try await retireUnpublished(bridge, budget: kvBudget, releasing: [laneID])
                throw NemotronSuperLocalKVBackend.Failure.decodeRowsRefused
            }
            rows = (id, rowsBytes)
        }
        // A speculating engine sizes its round work and captured windows once,
        // whatever the number of requests; reserve them before any request,
        // taking over the lease's round share (any excess is admitted here).
        if let leaseShares {
            guard await kvBudget.reducePendingLoad(loadLease, remainingWeightBytes: UInt64(leaseShares.bank))
            else {
                try await retireUnpublished(bridge, budget: kvBudget,
                    releasing: [laneID] + (rows.map { [$0.id] } ?? []))
                throw Failure.loadAdmissionLost
            }
        }
        let roundBytes = await bridge.superMTPOwnerBytes
        var round: (id: String, bytes: Int)?
        if roundBytes > 0 {
            let id = NemotronSuperLocalMTP.roundReservationID()
            guard roundBytes < Int.max,
                await kvBudget.reserveBytes(requestID: id, bytes: UInt64(roundBytes))
            else {
                try await retireUnpublished(bridge, budget: kvBudget,
                    releasing: [laneID] + (rows.map { [$0.id] } ?? []))
                throw NemotronSuperLocalMTP.Failure.roundRefused
            }
            round = (id, roundBytes)
        }
        // The bank keeps checkpoints between requests, beyond any request's
        // charge: its whole budget is reserved before the first request and
        // held until native retirement, like the lane.
        var bank: (id: String, bytes: Int)?
        if let prefixCache {
            let bytes = await bridge.superPrefixBankBytes
            let reserved = [laneID] + (rows.map { [$0.id] } ?? []) + (round.map { [$0.id] } ?? [])
            guard bytes == prefixCache.maximumBytes else {
                try await retireUnpublished(bridge, budget: kvBudget, releasing: reserved)
                throw NemotronSuperLocalPrefixCache.Failure.unavailable
            }
            if leaseShares != nil {
                guard await kvBudget.reducePendingLoad(loadLease, remainingWeightBytes: 0) else {
                    try await retireUnpublished(bridge, budget: kvBudget, releasing: reserved)
                    throw Failure.loadAdmissionLost
                }
            }
            let id = NemotronSuperLocalPrefixCache.bankReservationID()
            guard await kvBudget.reserveBytes(requestID: id, bytes: UInt64(bytes)) else {
                try await retireUnpublished(bridge, budget: kvBudget, releasing: reserved)
                throw NemotronSuperLocalPrefixCache.Failure.bankRefused
            }
            bank = (id, bytes)
        }
        // The dedicated image binding uses causal embeddings and no checkpoint
        // identity; with speculation installed the engine runs each image
        // request target-only, with no draft state. Image prompts prefill on
        // whichever KV storage the owner selected.
        return Owner(bridge: bridge, modelID: modelID, installed: installed, tokenizer: tokenizer,
                     budget: kvBudget, contextLength: sizing.maxContextLength,
                     speculates: mtp != nil, maximumLocalRequests: requests,
                     prefill: prefill, prefillLaneID: laneID, prefillLaneBytes: laneBytes,
                     prefixBankID: bank?.id, prefixBankBytes: bank?.bytes ?? 0,
                     decodeRowsID: rows?.id, decodeRowsBytes: rows?.bytes ?? 0,
                     mtpRoundID: round?.id, mtpRoundBytes: round?.bytes ?? 0)
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
    /// The engine's once-per-engine MTP bytes; zero without a speculating
    /// declaration that sizes them. `Int.max` when unresolved.
    var superMTPOwnerBytes: Int {
        guard let resolution = (ownedEngine as? EngineV2)?.resolvedMTPAdmission else { return 0 }
        guard case .bounded(let value) = resolution else { return Int.max }
        return value.ownerBytes
    }
    /// The constructed engine's checkpoint bank budget; zero without a bank.
    var superPrefixBankBytes: Int {
        (ownedEngine as? EngineV2)?.hybridPrefixCache?.config.maximumBytes ?? 0
    }
}
