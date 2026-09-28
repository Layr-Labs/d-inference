import Foundation
import MLX
import MLXLMCommon
import ProviderCoreFoundation

/// Actual owner generation, not an implied new token for every load. A stopped
/// server cannot silently reopen its native owner through a late acquire.
enum StandaloneNativeMiMoLifecycle {
    case unopened
    case open(MiMoV26NativeLifecycle)
    case closed(MiMoV26NativeLifecycle?)
}

/// Mutated only by the Standalone actor. Neither this value nor a task result
/// wraps a raw model/binding/array; the actual transaction owns native resources.
final class StandaloneNativeMiMoLoad {
    enum Phase: Equatable { case loading, staged, published, closing }
    let id = UUID()
    let modelID: String
    let load: MiMoV26ServingLoad
    var phase: Phase = .loading
    var controlTask: Task<Void, Error>?
    var setupTask: Task<Void, Error>?
    var candidate: StandaloneServer.CachedSlot?
    var retirement: MiMoV26NativeRetirement?
    var previousGrants: [StandaloneServer.ExistingSlotGrant] = []
    var consumers: [UUID: NativeLocalConsumerLease] = [:]
    var consumerReservations: Set<UUID> = []
    var consumerJoinTasks: [UUID: Task<Void, Never>] = [:]
    var cleanupTask: Task<Void, Never>?
    var lastRetirementProgress: [String]?
    var engineBinding: (engineID: UUID, contractID: UUID)?
    var containerID: ObjectIdentifier?
    /// Actor load-gate handoff only, never native completion authority.
    var evictionReclaimToken: UUID?
    var transaction: MiMoV26NativeLoadTransaction? { load.transaction }

    init(modelID: String, load: MiMoV26ServingLoad) {
        self.modelID = modelID
        self.load = load
    }
}

/// INTERNAL test-only routing/observation. No environment/config/API can set
/// these hooks, and none can return a model, engine, receipt or memory credit.
struct StandaloneNativeMiMoTestHooks: Sendable {
    enum Phase: Sendable {
        case beforeWeights, afterContainer, beforeBuild, afterBundle, beforeSeal, beforePublication, releaseCallbackTail
    }
    let modelID: String
    let directory: URL
    let observe: (@Sendable (Phase, UUID?) async throws -> Void)?
    /// After the real synchronous clear, not a replacement/return-value hook.
    var didClearCache: (@Sendable () -> Void)? = nil
}

extension StandaloneServer {
    /// Explicit synthetic identity only. This bypasses disabled advertisement
    /// for a bounded caller test; it does NOT qualify/activate the public family.
    func installSyntheticNativeMiMoForTesting(
        _ model: ModelInfo, hooks: StandaloneNativeMiMoTestHooks
    ) throws {
        guard model.id == hooks.modelID,
              model.id.hasPrefix("synthetic-native-standalone-"),
              model.modelType == "mimo_v2", hooks.directory.isFileURL,
              nativeMiMoTestHooks == nil, nativeMiMoLoads.isEmpty,
              !models.contains(where: { $0.id == model.id }) else {
            throw MiMoV26ServingLoadError.nativeOwnerMismatch
        }
        // The actual load still validates config/index/manifest and strict
        // tensor metadata. This hook replaces only the user-cache path lookup.
        nativeMiMoTestHooks = hooks
        models.append(model)
    }

    func isSyntheticNativeMiMoUnderTest(_ model: ModelInfo) -> Bool {
        model.modelType == "mimo_v2"
            && model.id.hasPrefix("synthetic-native-standalone-")
            && nativeMiMoTestHooks?.modelID == model.id
    }

    func nativeMiMoTestDirectory(for model: ModelInfo) -> URL? {
        guard isSyntheticNativeMiMoUnderTest(model) else { return nil }
        return nativeMiMoTestHooks?.directory
    }

    func observeNativeMiMoTestPhase(
        _ phase: StandaloneNativeMiMoTestHooks.Phase,
        modelID: String, transactionID: UUID?
    ) async throws {
        guard nativeMiMoTestHooks?.modelID == modelID else { return }
        try await nativeMiMoTestHooks?.observe?(phase, transactionID)
    }

    /// Process-level refusal only. A healthy result is not a completion or
    /// reclaim receipt; retirement still consumes the actual SDK/host outcome.
    func requireNativeMiMoNewWorkAllowed() throws {
        try MiMoV26NativeLoadRegistry.shared.requireNewNativeWorkAllowed()
        try nativeMiMoRegistry.requireNewNativeWorkAllowed()
        guard !MiMoV26NativeLoadRegistry.shared.hasUnretiredClosingTransactions,
              !nativeMiMoRegistry.hasUnretiredClosingTransactions else {
            throw StandaloneServerError.capacityUnavailable("Native work is still retiring; retry after confirmed completion")
        }
    }

    var nativeMiMoReclaimAllowed: Bool {
        guard !MiMoV26NativeLoadRegistry.shared.hasRetainedFault,
              !nativeMiMoRegistry.hasRetainedFault,
              !MiMoV26NativeLoadRegistry.shared.hasUnretiredClosingTransactions,
              !nativeMiMoRegistry.hasUnretiredClosingTransactions else { return false }
        // Hold the refusal fence until the actor also drops actual temporary/
        // staged/slot aliases after a genuine transaction retirement.
        return !nativeMiMoLoads.values.contains { $0.phase == .closing }
    }

    func nativeMiMoLifecycleForLoad() throws -> MiMoV26NativeLifecycle {
        try requireNativeMiMoNewWorkAllowed()
        switch nativeMiMoLifecycle {
        case .unopened:
            let token = try nativeMiMoRegistry.openLifecycle()
            nativeMiMoLifecycle = .open(token)
            return token
        case .open(let token): return token
        case .closed:
            throw StandaloneServerError.capacityUnavailable("Standalone native lifecycle is closed")
        }
    }

    /// Called synchronously BEFORE the first stop/drain await.
    func closeNativeMiMoLifecycle() throws {
        switch nativeMiMoLifecycle {
        case .unopened:
            nativeMiMoLifecycle = .closed(nil)
        case .open(let token):
            let closed = try nativeMiMoRegistry.closeLifecycle(token)
            nativeMiMoLifecycle = .closed(closed)
        case .closed: break
        }
        for state in nativeMiMoLoads.values {
            state.phase = .closing
            state.load.revoke()
            state.controlTask?.cancel()
            state.setupTask?.cancel()
            for lease in state.consumers.values { lease.closeAndCancel() }
        }
    }

    /// Only an explicit server start can reopen an already closed owner.
    func reopenNativeMiMoLifecycleForStart() throws {
        try requireNativeMiMoNewWorkAllowed()
        guard nativeMiMoLoads.isEmpty else {
            throw StandaloneServerError.capacityUnavailable("Prior native owner has not retired")
        }
        if case .closed(let token) = nativeMiMoLifecycle {
            let opened = try token.map { try nativeMiMoRegistry.reopenLifecycle($0) }
                ?? nativeMiMoRegistry.openLifecycle()
            nativeMiMoLifecycle = .open(opened)
        }
    }

    /// Invoked only after the real common load gate and membership check. The
    /// registry-owned task returns Void: no completed Task.result retains a
    /// CachedSlot/container across failure cleanup or survivor regrowth.
    func loadNativeMiMoSlot(
        modelID: String, modelInfo: ModelInfo, directory: URL,
        load: MiMoV26ServingLoad, preparation: SpecDecPreparation,
        allowEviction: Bool = true
    ) async throws {
        guard !lifecycleDraining, lifecycleState != .stopping else {
            isLoadingAny = false; releaseLoadGateWaiters()
            throw StandaloneServerError.capacityUnavailable("Standalone admission is draining")
        }
        let state = StandaloneNativeMiMoLoad(modelID: modelID, load: load)
        guard nativeMiMoLoads[modelID] == nil else {
            isLoadingAny = false; releaseLoadGateWaiters()
            throw StandaloneServerError.capacityUnavailable("Native owner is already present")
        }
        nativeMiMoLoads[modelID] = state // Before claim or any native/setup await.
        nativeMiMoLoadGateID = state.id
        modelsLoading.insert(modelID)
        // Standalone retains the exact outer control task even before permit
        // claim; the registry additionally owns the actual native setup task.
        // Both results are Void and cannot retain a hidden model/slot alias.
        let control = Task {
            try await self.prepareAndPublishNativeMiMo(modelID: modelID, modelInfo: modelInfo,
                directory: directory, load: load, preparation: preparation,
                allowEviction: allowEviction)
        }
        state.controlTask = control
        do {
            try await withTaskCancellationHandler {
                let result = await control.result
                state.controlTask = nil
                try result.get()
            } onCancel: {
                load.revoke()
                control.cancel()
            }
            await pushActivationReserve()
            try Task.checkCancellation()
            try load.transaction?.requireServingWorkAllowed()
            finishNativeMiMoLoadGate(modelID: modelID, ownerID: state.id, failure: nil)
            await applyDeferredModelsIfNeeded()
        } catch {
            let failure = error
            state.phase = .closing
            load.revoke()
            control.cancel()
            _ = await control.result // external join, never from this task itself
            state.controlTask = nil
            if let task = state.setupTask {
                task.cancel()
                _ = await task.result
                if let transaction = state.transaction {
                    await nativeMiMoRegistry.joinOwnedTasksFromOutside(transaction)
                }
                state.setupTask = nil
            }
            await retireNativeMiMoIfReady(modelID: modelID, expectedLoad: load, afterActualProgress: true)
            finishNativeMiMoLoadGate(modelID: modelID, ownerID: state.id, failure: failure)
            await applyDeferredModelsIfNeeded()
            throw failure
        }
    }

    private func prepareAndPublishNativeMiMo(
        modelID: String, modelInfo: ModelInfo, directory: URL,
        load: MiMoV26ServingLoad, preparation: SpecDecPreparation,
        allowEviction: Bool
    ) async throws {
        try requireNativeMiMoNewWorkAllowed()
        let lifecycle = try nativeMiMoLifecycleForLoad()
        await pushActivationReserve()
        try Task.checkCancellation()
        try requireNativeMiMoNewWorkAllowed()
        try await evictIfNeededForLoad(allowEviction: allowEviction)
        try requireNativeMiMoNewWorkAllowed()
        let required = ModelLoadAdmission.requiredToLoadGb(
            weightsGb: load.estimatedWeightsGb,
            headroomGb: Double(UnifiedMemoryCap.loadHeadroomBytes(
                activationReserveBytes: resolvedActivationReserveBytes)) / (1024 * 1024 * 1024))
        try await ensureMemoryHeadroomForLoad(requiredGb: required, allowEviction: allowEviction)
        try Task.checkCancellation()
        try requireNativeMiMoNewWorkAllowed()
        try load.claim(budget: kvBudget, lifecycle: lifecycle, registry: nativeMiMoRegistry)
        guard let transaction = load.transaction,
              let state = nativeMiMoLoads[modelID], state.load === load else {
            throw MiMoV26ServingLoadError.managedLoadRequired
        }
        let task = try nativeMiMoRegistry.launchOwnedTask(for: transaction) {
            try await transaction.performSetup {
                try await self.buildNativeMiMoCandidate(modelID: modelID, modelInfo: modelInfo,
                    directory: directory, load: load, preparation: preparation)
            }
        }
        state.setupTask = task
        try await withTaskCancellationHandler {
            let result = await task.result
            await nativeMiMoRegistry.joinOwnedTasksFromOutside(transaction)
            state.setupTask = nil
            try result.get()
            try checkNativeMiMoSetupOwner(modelID: modelID, load: load)
            try await observeNativeMiMoTestPhase(.beforeSeal, modelID: modelID, transactionID: transaction.id)
            try checkNativeMiMoSetupOwner(modelID: modelID, load: load)
            _ = try await load.sealConstructionForPublication()
            try await observeNativeMiMoTestPhase(.beforePublication, modelID: modelID, transactionID: transaction.id)
            try checkNativeMiMoSetupOwner(modelID: modelID, load: load)
            guard let candidate = state.candidate else { throw MiMoV26ServingLoadError.nativeOwnerMismatch }
            // All throwing/awaited vetoes precede the real slot insertion.
            try load.commitPublication {
                slots[modelID] = candidate
                state.candidate = nil
                state.phase = .published
                state.previousGrants = []
                modelsLoading.remove(modelID)
            }
        } onCancel: {
            load.revoke()
            task.cancel()
        }
    }

    func checkNativeMiMoSetupOwner(modelID: String, load: MiMoV26ServingLoad) throws {
        try Task.checkCancellation()
        try requireNativeMiMoNewWorkAllowed()
        guard nativeMiMoLoads[modelID]?.load === load,
              models.contains(where: { $0.id == modelID }),
              lifecycleState != .stopping,
              case .open = nativeMiMoLifecycle else { throw CancellationError() }
        try load.recheck()
    }

    private func buildNativeMiMoCandidate(
        modelID: String, modelInfo: ModelInfo, directory: URL,
        load: MiMoV26ServingLoad, preparation: SpecDecPreparation
    ) async throws {
        try checkNativeMiMoSetupOwner(modelID: modelID, load: load)
        let transactionID = load.transaction?.id
        try await observeNativeMiMoTestPhase(.beforeWeights, modelID: modelID, transactionID: transactionID)
        try checkNativeMiMoSetupOwner(modelID: modelID, load: load)
        let hashRequired = PrefixCachePolicy.requiresLoadHashBracket(modelId: modelID, modelDirectory: directory)
        let beforeHash = await computeStandaloneWeightHash(modelPath: directory, modelId: modelID, required: hashRequired)
        try checkNativeMiMoSetupOwner(modelID: modelID, load: load)
        _ = try GPUEnforcement.requireMetal()
        MLXMemoryGuard.configureOnce()
        guard Qwen4ExpLoadFootprint.isCurrent(modelInfo, directory: directory) else {
            throw StandaloneServerError.capacityUnavailable("Model loading footprint changed; rescan the model")
        }
        let container = try await ModelContainerLoading.loadServingContainer(
            from: directory, modelID: modelID, nativeMiMoLoad: load)
        try checkNativeMiMoSetupOwner(modelID: modelID, load: load)
        try await observeNativeMiMoTestPhase(.afterContainer, modelID: modelID, transactionID: transactionID)
        let afterHash = await computeStandaloneWeightHash(modelPath: directory, modelId: modelID, required: hashRequired)
        try checkNativeMiMoSetupOwner(modelID: modelID, load: load)
        let cacheHash: String?
        if hashRequired {
            switch ProviderLoop.reusableSSDWeightHashDecision(preLoadHash: beforeHash, postLoadHash: afterHash) {
            case .eligible(let hash): cacheHash = hash
            case .unavailable:
                cacheHash = nil
                standaloneLogger.warning("Reusable SSD cache disabled: cryptographic weight hash unavailable")
            case .changed:
                throw StandaloneServerError.capacityUnavailable("Model changed across the load hash bracket")
            }
        } else { cacheHash = nil }
        let targetSizing = await container.sizing(modelPath: directory, defaultMaxTokens: Self.slotDefaultMaxTokens)
        let tokenizer = await container.tokenizerHandle(modelType: modelInfo.modelType, directory: directory)
        try checkNativeMiMoSetupOwner(modelID: modelID, load: load)
        guard nativeMiMoReclaimAllowed else { throw CancellationError() }
        MLX.Memory.clearCache()
        nativeMiMoTestHooks?.didClearCache?()
        guard KVHeadroomProbe.hasServeableKVHeadroom(activationReserveBytes: resolvedActivationReserveBytes) else {
            throw StandaloneServerError.capacityUnavailable("Loaded native model has insufficient live KV headroom")
        }
        let prepared = try await EngineV2SlotFactory.prepareProductionModel(
            modelId: modelID, isVLM: false, modelDirectory: directory,
            container: container, specDecPreparation: preparation,
            emitTelemetry: v2TestHooks?.emitTelemetry)
        try checkNativeMiMoSetupOwner(modelID: modelID, load: load)
        let sizing = targetSizing.replacingAuxiliaryWeightBytes(prepared.assistantBytes)
        let existing = await existingSlotGrants(excludingModelId: modelID)
        try checkNativeMiMoSetupOwner(modelID: modelID, load: load)
        let targets = EngineV2KVSizing.resliceGrants(existing: existing.map(\.slot),
            newcomer: .init(modelId: modelID, fp16KVBytesPerToken: sizing.fp16KVBytesPerToken,
                maxContextLength: sizing.maxContextLength),
            fleetKVBudgetBytes: fleetKVBudgetBytes(extraWeightBytes: sizing.weightsBytes))
        guard EngineV2KVSizing.resliceMeetsServiceabilityFloor(targets, fixedCarveBytes: [:]) else {
            EngineV2Factory.emitRefusalTelemetry(modelId: modelID, reason: .resliceFloor,
                error: nil, emitTelemetry: v2TestHooks?.emitTelemetry)
            throw StandaloneServerError.capacityUnavailable("Native load would violate the shared KV serviceability floor")
        }
        nativeMiMoLoads[modelID]?.previousGrants = existing
        for entry in existing {
            try checkNativeMiMoSetupOwner(modelID: modelID, load: load)
            if let grant = targets[entry.slot.modelId], grant < entry.previousGrant {
                await entry.bridge.updateKVBytesCapacity(grant)
            }
        }
        try await observeNativeMiMoTestPhase(.beforeBuild, modelID: modelID, transactionID: transactionID)
        try checkNativeMiMoSetupOwner(modelID: modelID, load: load)
        let bundle = try await EngineV2SlotFactory.makeProductionBundle(
            modelId: modelID, modelType: modelInfo.modelType, isVLM: false, modelDirectory: directory,
            container: container, tokenizer: tokenizer, sizing: sizing,
            kvBytesCapacity: targets[modelID] ?? 0, maxConcurrentRequests: engineV2MaxConcurrent(forModel: modelID),
            kvBudget: kvBudget, activationReserveBytes: resolvedActivationReserveBytes,
            kvBackendConfig: config.engineV2KVBackend, kvBackendConfigByModel: config.engineV2KVBackendByModel,
            prefillDeadlineMode: config.prefillDeadlineMode, weightHash: cacheHash,
            specDecPreparation: preparation, preparedModel: prepared,
            emitTelemetry: v2TestHooks?.emitTelemetry)
        // The corrected factory/transaction already owns this actual bundle.
        // Keep the actor's candidate before any later awaited veto as well.
        nativeMiMoLoads[modelID]?.candidate = CachedSlot(bundle: bundle, modelContainer: container,
            tokenizer: tokenizer, modelType: modelInfo.modelType, isVLM: false, sizing: sizing,
            lastUsedAt: .now, cacheEligibleWeightHash: cacheHash)
        nativeMiMoLoads[modelID]?.containerID = container.identity
        guard let actualEngine = await bundle.bridge.ownedEngine as? EngineV2,
              let actualContractID = actualEngine.nativeShutdownExecutionContractID else {
            throw MiMoV26ServingLoadError.nativeOwnerMismatch
        }
        nativeMiMoLoads[modelID]?.engineBinding = (actualEngine.nativeShutdownEngineID, actualContractID)
        if nativeMiMoLoads[modelID]?.phase != .closing {
            nativeMiMoLoads[modelID]?.phase = .staged
        }
        try await observeNativeMiMoTestPhase(.afterBundle, modelID: modelID, transactionID: transactionID)
        try checkNativeMiMoSetupOwner(modelID: modelID, load: load)
        guard nativeMiMoReclaimAllowed else { throw CancellationError() }
        MLX.Memory.clearCache()
        nativeMiMoTestHooks?.didClearCache?()
        let postBuild = KVHeadroomProbe.postBuildServeable(kvBackendKind: bundle.bridge.kvBackendKind,
            pagedPoolBytes: await bundle.bridge.kvBackendPoolBytes(),
            activationReserveBytes: resolvedActivationReserveBytes)
        try checkNativeMiMoSetupOwner(modelID: modelID, load: load)
        let runtimeMTP = await bundle.bridge.mtpStatusSnapshot().active
        try checkNativeMiMoSetupOwner(modelID: modelID, load: load)
        let wantsMTP = preparation.status.configured && preparation.status.reason == nil
        guard !wantsMTP || (bundle.mtpStatus.active && runtimeMTP) else {
            throw StandaloneServerError.capacityUnavailable("Explicit native MTP did not activate; warm rebuild is unsupported")
        }
        guard postBuild else {
            throw StandaloneServerError.capacityUnavailable("Native engine build left insufficient live KV headroom")
        }
        for entry in existing {
            try checkNativeMiMoSetupOwner(modelID: modelID, load: load)
            if let grant = targets[entry.slot.modelId], grant > entry.previousGrant {
                await entry.bridge.updateKVBytesCapacity(grant)
            }
        }
    }

    func finishNativeMiMoLoadGate(modelID: String, ownerID: UUID, failure: (any Error)?) {
        guard nativeMiMoLoadGateID == ownerID else { return }
        nativeMiMoLoadGateID = nil
        isLoadingAny = false
        for waiter in loadingWaiters.removeValue(forKey: modelID) ?? [] {
            if let failure { waiter.resume(throwing: failure) }
            else { waiter.resume() }
        }
        releaseLoadGateWaiters()
    }

    func isNativeMiMoSlot(_ modelID: String) -> Bool {
        if nativeMiMoLoads[modelID] != nil { return true }
        if case .nativeMiMo? = slots[modelID]?.modelContainer { return true }
        return slots[modelID]?.modelType == "mimo_v2"
    }

    /// Graceful activity only, NOT completion/refund authority. Idle published
    /// owners do not keep admission drain alive; actual accepted leases include
    /// their release callback tail until its real external join removes them.
    var nativeMiMoGracefulWorkCount: Int {
        nativeMiMoLoads.values.reduce(0) { count, state in
            let setup = state.controlTask != nil || state.setupTask != nil
                || state.phase == .loading || state.phase == .staged
            let unresolved = state.phase == .closing
            return count + max(state.consumers.count, setup || unresolved ? 1 : 0)
        }
    }

    /// Native acquisition owns its real host-consumer lease before it returns.
    /// Counts may control admission, but never substitute for this lease's
    /// actual task joins or the transaction's SDK/bridge completion receipt.
    func makeNativeMiMoReleaseToken(modelID: String) throws -> OneShotRelease? {
        guard let state = nativeMiMoLoads[modelID] else {
            if isNativeMiMoSlot(modelID) { throw MiMoV26ServingLoadError.managedLoadRequired }
            return nil
        }
        guard state.phase == .published, let transaction = state.transaction else {
            throw StandaloneServerError.capacityUnavailable("Native model is not published")
        }
        guard let slot = slots[modelID],
              case .nativeMiMo(let container, let load) = slot.modelContainer,
              load === state.load, ObjectIdentifier(container) == state.containerID,
              transaction.registeredBridgeForRetirement() === slot.bridge else {
            throw MiMoV26ServingLoadError.nativeOwnerMismatch
        }
        try transaction.requireServingWorkAllowed()
        let lease = NativeLocalConsumerLease()
        let transactionID = transaction.id, leaseID = lease.id
        state.consumers[leaseID] = lease
        state.consumerReservations.insert(leaseID)
        return OneShotRelease(release: { [weak self] model in
            await self?.releaseNativeMiMoAcquisition(modelID: model,
                transactionID: transactionID, leaseID: leaseID)
            try? await self?.observeNativeMiMoTestPhase(.releaseCallbackTail,
                modelID: model, transactionID: transactionID)
        }, modelId: modelID, nativeConsumerLease: lease)
    }

    func releaseNativeMiMoAcquisition(modelID: String, transactionID: UUID, leaseID: UUID) {
        guard let state = nativeMiMoLoads[modelID], state.transaction?.id == transactionID,
              let lease = state.consumers[leaseID],
              state.consumerReservations.remove(leaseID) != nil else { return }
        // Logical reservation release is NOT callback-return completion. Keep
        // the actual lease in the owner map until an external join completes.
        releaseSlot(modelID)
        state.consumerJoinTasks[leaseID] = Task.detached { [weak self] in
            // Detached intentionally does not inherit the calling lease's
            // TaskLocal identity; the real callback may still be returning.
            await lease.joinFromOutside()
            await self?.finishNativeMiMoConsumerJoin(modelID: modelID,
                transactionID: transactionID, leaseID: leaseID)
        }
        if state.phase == .closing {
            startNativeMiMoRetirement(modelID: modelID, expectedLoad: state.load, afterActualProgress: true)
        }
    }

    private func finishNativeMiMoConsumerJoin(modelID: String, transactionID: UUID, leaseID: UUID) {
        guard let state = nativeMiMoLoads[modelID], state.transaction?.id == transactionID,
              let lease = state.consumers[leaseID] else { return }
        let phase = lease.snapshot().phase
        guard phase == .completed || phase == .abandoned else { return }
        state.consumers.removeValue(forKey: leaseID)
        state.consumerJoinTasks.removeValue(forKey: leaseID)
        if state.phase == .closing {
            startNativeMiMoRetirement(modelID: modelID, expectedLoad: state.load, afterActualProgress: true)
        }
    }

    private func nativeMiMoRetirementProgress(_ state: StandaloneNativeMiMoLoad) async -> [String] {
        var value = [
            state.controlTask == nil ? "control-joined" : "control-held",
            state.setupTask == nil ? "setup-joined" : "setup-held",
            String(kvBudget.processLedger.policySnapshot().epoch),
        ]
        if let transaction = state.transaction {
            let snapshot = transaction.snapshot()
            value += [snapshot.phase.rawValue, String(snapshot.activeOperations),
                String(snapshot.constructionEpoch), String(describing: snapshot.permit?.ownerState?.revision)]
            if snapshot.constructionFailed || snapshot.phase == .retainedFault {
                return value + ["known-native-fault"] // no bridge await on retained work
            }
            if let bridge = transaction.registeredBridgeForRetirement() {
                value += await bridge.nativeRetirementTaskSnapshot().progress.map(String.init)
            }
        }
        for key in state.consumers.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            if let snapshot = state.consumers[key]?.snapshot() {
                value += [key.uuidString, String(snapshot.revision)]
            }
        }
        return value
    }

    /// The caller supplies progress only from an actual completed task or lease
    /// callback. Otherwise compare real state changes; no repeated timer grants
    /// permission to retry or interprets map counts as completed native work.
    func startNativeMiMoRetirement(
        modelID: String, expectedLoad: MiMoV26ServingLoad, afterActualProgress: Bool
    ) {
        guard let state = nativeMiMoLoads[modelID], state.load === expectedLoad,
              state.cleanupTask == nil else { return }
        state.phase = .closing
        evictingModels.insert(modelID)
        state.load.revoke()
        state.controlTask?.cancel()
        state.setupTask?.cancel()
        state.cleanupTask = Task.detached { [weak self] in
            // A callback-triggered cleanup must not inherit its lease TaskLocal
            // and then join itself. Actor lookup still binds the exact owner.
            guard let self else { return }
            await self.runNativeMiMoRetirementCoordinator(modelID: modelID,
                expectedLoad: expectedLoad, afterActualProgress: afterActualProgress)
        }
    }

    private func runNativeMiMoRetirementCoordinator(
        modelID: String, expectedLoad: MiMoV26ServingLoad, afterActualProgress: Bool
    ) async {
        guard let state = nativeMiMoLoads[modelID], state.load === expectedLoad else { return }
        if let actual = state.transaction?.snapshot(),
           actual.constructionFailed || actual.phase == .retainedFault {
            // Even retry/progress inspection must not wait on the failed bridge.
            state.retirement = await state.load.finishFailureAfterUnwind()
            state.cleanupTask = nil
            return
        }
        let progress = await nativeMiMoRetirementProgress(state)
        guard afterActualProgress || state.lastRetirementProgress != progress else {
            state.cleanupTask = nil
            return
        }
        let outcome = await performNativeMiMoRetirement(state)
        state.retirement = outcome
        // All native engine/task locals are out of the preceding frame.
        if case .retired = outcome {
            await finishRetiredNativeMiMoOwner(modelID: modelID, state: state)
        } else if case .notClaimed = outcome, state.transaction == nil {
            removeUnstartedNativeMiMoOwner(modelID: modelID, state: state)
            await pushActivationReserve()
        }
        state.lastRetirementProgress = await nativeMiMoRetirementProgress(state)
        state.cleanupTask = nil
        await finishNativeMiMoStopAfterProgress()
    }

    func retireNativeMiMoIfReady(
        modelID: String, expectedLoad: MiMoV26ServingLoad, afterActualProgress: Bool
    ) async {
        startNativeMiMoRetirement(modelID: modelID, expectedLoad: expectedLoad,
            afterActualProgress: afterActualProgress)
        let task = nativeMiMoLoads[modelID]?.cleanupTask
        await task?.value
    }

    func startNativeMiMoRetirementsForStop() {
        for (modelID, state) in nativeMiMoLoads {
            startNativeMiMoRetirement(modelID: modelID, expectedLoad: state.load, afterActualProgress: false)
        }
    }

    func retireAllNativeMiMoForStop() async {
        startNativeMiMoRetirementsForStop()
        let tasks = nativeMiMoLoads.values.compactMap(\.cleanupTask)
        for task in tasks { await task.value }
    }

    private func performNativeMiMoRetirement(_ state: StandaloneNativeMiMoLoad) async -> MiMoV26NativeRetirement {
        if let transaction = state.transaction {
            let actual = transaction.snapshot()
            if actual.constructionFailed || actual.phase == .retainedFault {
                // Core checks its actual work/fault before task count or native
                // awaits. Do not initiate another fence on already-failed work.
                return await state.load.finishFailureAfterUnwind()
            }
        }
        // These are separate retained task handles, not this cleanup Task.
        if let task = state.controlTask { _ = await task.result; state.controlTask = nil }
        if let task = state.setupTask { _ = await task.result; state.setupTask = nil }
        guard let transaction = state.transaction else { return .notClaimed }
        let afterSetup = transaction.snapshot()
        if afterSetup.constructionFailed || afterSetup.phase == .retainedFault {
            return await state.load.finishFailureAfterUnwind()
        }
        await nativeMiMoRegistry.joinOwnedTasksFromOutside(transaction)
        let afterRegistryJoin = transaction.snapshot()
        if afterRegistryJoin.constructionFailed || afterRegistryJoin.phase == .retainedFault {
            return await state.load.finishFailureAfterUnwind()
        }
        let consumers = Array(state.consumers.values)
        for lease in consumers {
            lease.closeAndCancel()
            if lease.snapshot().hasOutstandingHandoff {
                do {
                    switch try lease.abandonUnstartedHandoff() {
                    case .unbound, .alreadyAbandoned:
                        releaseNativeMiMoAcquisition(modelID: state.modelID,
                            transactionID: transaction.id, leaseID: lease.id)
                    case .boundReleaseRequested: break
                    }
                } catch {
                    // Registered work is not cold-disposable. Its actual task
                    // handles remain owned and will be joined after SDK proof.
                }
            }
        }
        if let bridge = transaction.registeredBridgeForRetirement() {
            if let engine = await bridge.ownedEngine as? EngineV2 {
                guard let contractID = engine.nativeShutdownExecutionContractID else {
                    return .pending(.engineProofUnavailable)
                }
                if let expected = state.engineBinding {
                    guard expected.engineID == engine.nativeShutdownEngineID,
                          expected.contractID == contractID else { return .pending(.identityMismatch) }
                } else {
                    // Failed construction can register an engine before the
                    // caller has returned to save this metadata-only binding.
                    state.engineBinding = (engine.nativeShutdownEngineID, contractID)
                }
                do {
                    let outcome = try await bridge.shutdownNativeConstruction(
                        expectedEngine: engine, executionContractID: contractID)
                    if case .incomplete = outcome {
                        return await state.load.finishFailureAfterUnwind()
                    }
                } catch MiMoV26NativeBridgeShutdownError.pendingConsumers {
                    // Can mean another call is still awaiting GPU. Only the
                    // recorded actual SDK receipt below permits host joins.
                } catch {
                    return .pending(.hostConsumers)
                }
            }
            let observed = await bridge.nativeRetirementTaskSnapshot()
            guard let expected = state.engineBinding, let receipt = observed.sdkQuiescence,
                  receipt.engineID == expected.engineID,
                  receipt.executionContractID == expected.contractID, receipt.generation == 1 else {
                // Never let a cached host-only zero or nil engine retire a
                // still-live local consumer. Only the confirmed incomplete
                // branch above may delegate fault retention before host joins.
                return .pending(.engineProofUnavailable)
            }
            // The v1 profile/owner/epoch was validated at actual engine/bundle
            // registration and is checked again by TX.retire, not asserted here.
            for lease in consumers { await lease.joinFromOutside() }
            for task in observed.tasks { await task.value }
            let later = await bridge.nativeRetirementTaskSnapshot()
            guard later.sdkQuiescence == observed.sdkQuiescence else { return .pending(.identityMismatch) }
            for task in later.tasks { await task.value }
        } else if !consumers.isEmpty {
            return .pending(.engineProofUnavailable)
        }
        // Only this consumes final SDK + bridge/late-task revalidation and
        // settles the actual permit. Neither task joins nor zeros mint credit.
        return await state.load.finishFailureAfterUnwind()
    }

    private func removeUnstartedNativeMiMoOwner(modelID: String, state: StandaloneNativeMiMoLoad) {
        guard nativeMiMoLoads[modelID] === state, state.controlTask == nil,
              state.setupTask == nil, state.candidate == nil, state.previousGrants.isEmpty,
              state.transaction == nil else { return }
        nativeMiMoLoads.removeValue(forKey: modelID)
        modelsLoading.remove(modelID)
        evictingModels.remove(modelID)
    }

    private func finishRetiredNativeMiMoOwner(modelID: String, state: StandaloneNativeMiMoLoad) async {
        guard nativeMiMoLoads[modelID] === state else { return }
        // Exact actual facade identity: never delete a replacement slot.
        if case .nativeMiMo(_, let load)? = slots[modelID]?.modelContainer, load === state.load {
            slots.removeValue(forKey: modelID)
            slotReservations.removeValue(forKey: modelID)
        }
        state.candidate = nil
        state.controlTask = nil
        state.setupTask = nil
        state.consumers = [:]
        state.consumerReservations = []
        state.consumerJoinTasks = [:]
        nativeMiMoLoads.removeValue(forKey: modelID)
        modelsLoading.remove(modelID)
        evictingModels.remove(modelID)
        if lifecycleState == .stopping || lifecycleDraining {
            // Global stop clears once after ALL actual owners/ordinary slots
            // finish. It must not regrow survivors while closing admissions.
            state.previousGrants = []
            await pushActivationReserve()
            return
        }
        // An eviction caller already holds the common load gate. It reclaims
        // only after this helper frame/its native aliases have returned.
        if state.evictionReclaimToken != nil { await pushActivationReserve(); return }
        let restoreExact = nativeMiMoLoadGateID == state.id
        var acquiredGate = false
        if !restoreExact {
            while isLoadingAny {
                await withCheckedContinuation { loadGateWaiters.append($0) }
            }
            isLoadingAny = true
            acquiredGate = true
        }
        defer {
            if acquiredGate { isLoadingAny = false; releaseLoadGateWaiters() }
        }
        guard nativeMiMoReclaimAllowed else { return }
        MLX.Memory.clearCache()
        nativeMiMoTestHooks?.didClearCache?()
        await pushActivationReserve()
        guard nativeMiMoReclaimAllowed,
              KVHeadroomProbe.hasServeableKVHeadroom(activationReserveBytes: resolvedActivationReserveBytes) else { return }
        if restoreExact {
            for entry in state.previousGrants {
                guard nativeMiMoReclaimAllowed else { return }
                guard slots[entry.slot.modelId]?.bridge === entry.bridge else { continue }
                await entry.bridge.updateKVBytesCapacity(entry.previousGrant)
            }
        }
        state.previousGrants = []
        await resliceGrowSurvivors()
    }

    private func finishNativeMiMoStopAfterProgress() async {
        guard lifecycleState == .stopping, shutdownTask == nil,
              nativeMiMoLoads.isEmpty else { return }
        let task = Task { await self.finishShutdown(serviceTask: nil) }
        shutdownTask = task
    }
}
