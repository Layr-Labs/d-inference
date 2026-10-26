import Foundation
import DarkbloomClusterRemote
import MLXLMCommon

// The cluster pair as an ordinary provider slot (S09).
//
// A leader member serves its pair's one model through the same `ModelSlot`,
// EngineV2 bridge, inference handler, cancellation and heartbeat a solo
// provider uses. Nothing here loads weights or touches Metal: the two owner
// processes hold the model, and the slot holds only the bridge built by
// `DistributedEngineFactory.makeRegistryEntry` over their execution owner. The
// coordinator then sees one loaded slot and a provider that is not draining
// (C14), and routes `inference_request` to it like any other.
//
// Modelled on `ProviderLoop+NativeMiMo.swift` (an out-of-process owner behind
// a published slot), without its in-process native transaction: the owner's
// own readiness decides whether the slot exists. Losing either rank retires
// the slot at once; a retired slot is never republished. The member session
// that committed the start publishes a fresh one for its next start.

/// What a pair slot serves: the pair's one model, as the leader's installed
/// setup describes it. The caller loads the tokenizer from the model's
/// directory (metadata only) and keeps the owner it passes to `publish`.
public struct ClusterPairSlotSpecification: Sendable {
    public let publicModelID: String
    public let modelType: String?
    public let tokenizer: TokenizerHandle
    public let eosTokenIDs: Set<Int>
    public let expectedIdentity: DistributedResidentIdentity
    public let profile: DistributedResidentExecutionProfile
    public let firstTokenBudgetPolicy: DistributedFirstTokenBudgetPolicy?
    public let residentPrefixEvidence: ResidentPrefixCacheEvidence?
    /// The artifact's total weight bytes across both ranks. Diagnostics and
    /// sizing only: no byte of it is resident in this process.
    public let artifactBytes: Int
    /// Per-request pair telemetry for this slot (S24); nil records nothing.
    public let pairTelemetry: DistributedPairTelemetryContext?
    /// The model's directory on this Mac. With it the slot's stop set and
    /// sampling defaults are a single-Mac slot's (`DistributedEngineFactory`).
    public let modelDirectory: URL?

    public init(publicModelID: String, modelType: String?, tokenizer: TokenizerHandle, eosTokenIDs: Set<Int>,
                expectedIdentity: DistributedResidentIdentity, profile: DistributedResidentExecutionProfile,
                firstTokenBudgetPolicy: DistributedFirstTokenBudgetPolicy? = nil,
                residentPrefixEvidence: ResidentPrefixCacheEvidence? = nil, artifactBytes: Int = 0,
                modelDirectory: URL? = nil, pairTelemetry: DistributedPairTelemetryContext? = nil) {
        self.publicModelID = publicModelID; self.modelType = modelType; self.tokenizer = tokenizer
        self.eosTokenIDs = eosTokenIDs; self.expectedIdentity = expectedIdentity; self.profile = profile
        self.firstTokenBudgetPolicy = firstTokenBudgetPolicy; self.residentPrefixEvidence = residentPrefixEvidence
        self.artifactBytes = max(0, artifactBytes); self.modelDirectory = modelDirectory
        self.pairTelemetry = pairTelemetry
    }
}

// `ClusterPairSlotError` lives beside the serving seam (Coordinator/NativePairMemberServing.swift).

/// Identity of one published pair slot. `ProviderModelContainer.clusterPair`
/// carries it, so the slot has a container identity without a container.
final class ClusterPairSlotHandle: @unchecked Sendable {
    let id = UUID()
    let modelID: String
    /// The pair session's membership epoch (a committed start's epoch).
    let membershipEpoch: UUID
    let tokenizer: TokenizerHandle
    let sizing: SlotSizingSnapshot
    let owner: ClusterPairSlotOwner
    let publishedAt = ContinuousClock.now

    init(modelID: String, membershipEpoch: UUID, tokenizer: TokenizerHandle, sizing: SlotSizingSnapshot,
         owner: ClusterPairSlotOwner) {
        self.modelID = modelID; self.membershipEpoch = membershipEpoch; self.tokenizer = tokenizer
        self.sizing = sizing; self.owner = owner
    }
}

/// The execution owner as the slot's engine sees it, with one addition: the
/// slot also hears every readiness loss. The engine installs the owner's one
/// invalidation observer, so this forwards everything else unchanged and
/// fans that one notification out to both.
final class ClusterPairSlotOwner: DistributedDeadlineExecutionOwner, @unchecked Sendable {
    private let inner: any DistributedResidentExecutionOwner
    private let lock = NSLock()
    private var engineHandler: (@Sendable () -> Void)?
    private var slotHandler: (@Sendable () -> Void)?
    private var invalidated = false

    init(_ inner: any DistributedResidentExecutionOwner) {
        self.inner = inner
        inner.setReadinessInvalidationHandler { [weak self] in self?.invalidate() }
    }

    var hasLostReadiness: Bool { lock.withLock { invalidated } }

    private func invalidate() {
        let handlers = lock.withLock { () -> [(@Sendable () -> Void)?] in
            invalidated = true
            return [engineHandler, slotHandler]
        }
        for handler in handlers { handler?() }
    }

    /// The slot's own observer. Installed after a loss, it runs at once.
    func setSlotInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        let lost = lock.withLock { slotHandler = handler; return invalidated }
        if lost { handler() }
    }

    func readiness() -> DistributedResidentReadiness? {
        hasLostReadiness ? nil : inner.readiness()
    }
    /// The pair's batch lanes: the slot's engine admits as many requests at
    /// once as the pair it wraps serves (the protocol default would be one).
    var concurrentRequests: Int { inner.concurrentRequests }
    func setReadinessInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        let lost = lock.withLock { engineHandler = handler; return invalidated }
        if lost { handler() }
    }
    func projectFirstToken(_ request: CBv2Request, admission: CBv2FirstTokenDeadlineAdmission) -> CBv2FirstTokenProjectedWork {
        inner.projectFirstToken(request, admission: admission)
    }
    func reserve(_ request: CBv2Request, identity: DistributedResidentIdentity,
                 profileID: String, capacityLimit: Int) throws -> any DistributedResidentRequestLease {
        guard !hasLostReadiness else { throw DistributedEngineError.unavailable }
        return try inner.reserve(request, identity: identity, profileID: profileID, capacityLimit: capacityLimit)
    }
    func reserve(_ request: CBv2Request, identity: DistributedResidentIdentity, profileID: String,
                 capacityLimit: Int, deadlineContext: DistributedRequestDeadlineContext) throws -> any DistributedResidentRequestLease {
        guard !hasLostReadiness else { throw DistributedEngineError.unavailable }
        if let deadlineOwner = inner as? any DistributedDeadlineExecutionOwner {
            return try deadlineOwner.reserve(request, identity: identity, profileID: profileID,
                capacityLimit: capacityLimit, deadlineContext: deadlineContext)
        }
        return try inner.reserve(request, identity: identity, profileID: profileID, capacityLimit: capacityLimit)
    }
    func shutdown() async { await inner.shutdown() }
}

extension ProviderLoop {
    /// The model of the pair slot this member serves, if one is published.
    var clusterPairSlotModelID: String? { clusterPairSlot?.modelID }

    /// Whether this member serves `modelID` through a live pair slot now.
    func clusterPairSlotServes(_ modelID: String) -> Bool {
        guard let handle = clusterPairSlot, handle.modelID == modelID,
              case .clusterPair(let published)? = modelSlots[modelID]?.modelContainer, published === handle else { return false }
        return !modelsUnloading.contains(modelID) && !handle.owner.hasLostReadiness
    }

    /// A member admits coordinator work only while it serves a pair slot and
    /// nothing else (drain, stop, a retirement reconnect) refuses it. The
    /// heartbeat reads this: one loaded slot and not draining, or draining
    /// with no slot.
    func refreshClusterMemberAdmission() {
        guard isClusterMember else { return }
        let serving = clusterPairSlot.map { clusterPairSlotServes($0.modelID) } ?? false
        state.refusingNewWork = !serving || isDraining || isShuttingDown || isReconnectingAfterRetirement
        // The client forwards requests while a slot exists, even a retiring
        // one, so each is answered by the loop with its own terminal.
        state.memberPairSlotModel = clusterPairSlot?.modelID
    }

    /// Publish the pair's slot. `owner` must already be ready (both ranks
    /// loaded). On success the slot's engine owns `owner` and retirement
    /// shuts it down; on a throw the caller still owns it and must shut it
    /// down, exactly as `DistributedEngineFactory` documents.
    @discardableResult
    public func publishClusterPairSlot(_ specification: ClusterPairSlotSpecification,
                                       owner inner: any DistributedResidentExecutionOwner) async throws -> UUID {
        try requireClusterPairPublication(specification.publicModelID)
        guard let ready = inner.readiness(), ready.identity == specification.expectedIdentity,
              ready.profileID == specification.profile.id, ready.requestCapacityBytes > 0 else {
            throw ClusterPairSlotError.ownerUnavailable
        }
        let owner = ClusterPairSlotOwner(inner)
        let entry: MultiModelBatchSchedulerEngine.ModelRegistryEntry
        do {
            entry = try DistributedEngineFactory.makeRegistryEntry(
                owner: owner, expectedIdentity: specification.expectedIdentity,
                publicModelID: specification.publicModelID, profile: specification.profile,
                tokenizer: specification.tokenizer, eosTokenIDs: specification.eosTokenIDs,
                modelType: specification.modelType, firstTokenBudgetPolicy: specification.firstTokenBudgetPolicy,
                residentPrefixEvidence: specification.residentPrefixEvidence,
                modelDirectory: specification.modelDirectory, pairTelemetry: specification.pairTelemetry)
        } catch { throw ClusterPairSlotError.ownerUnavailable }
        guard let bridge = entry.engineV2Bridge else { throw ClusterPairSlotError.ownerUnavailable }
        let profile = specification.profile
        let sizing = SlotSizingSnapshot(weightsBytes: specification.artifactBytes, fp16KVBytesPerToken: 0,
            maxContextLength: profile.maxContextTokens,
            defaultMaxTokens: min(profile.maxOutputTokens, Self.schedulerDefaultMaxTokens))
        let handle = ClusterPairSlotHandle(modelID: specification.publicModelID,
            membershipEpoch: specification.expectedIdentity.membershipEpoch,
            tokenizer: specification.tokenizer, sizing: sizing, owner: owner)
        // No suspension since the checks above: publication is atomic on
        // this actor with them.
        try requireClusterPairPublication(specification.publicModelID)
        modelSlots[specification.publicModelID] = ModelSlot(
            engineBundle: ProviderEngineBundle(targetOnly: bridge), modelContainer: .clusterPair(handle),
            tokenizer: specification.tokenizer, sizing: sizing,
            modelArtifactSHA256: specification.expectedIdentity.artifactSHA256, cacheEligibleWeightHash: nil,
            isVLM: false, modelType: specification.modelType, lastInferenceAt: .now)
        clusterPairSlot = handle
        let id = handle.id
        owner.setSlotInvalidationHandler { [weak self] in
            Task { await self?.retireClusterPairSlot(id, reason: Self.readinessLostReason) }
        }
        await engineV2Runtime.register(modelId: specification.publicModelID, bridge: bridge)
        // A loss or stop during the registration hop retires this slot; do
        // not reopen admission over it.
        guard clusterPairSlot === handle else { return id }
        // Warmup canary (S18): one throwaway generation before admission
        // opens; a pair that cannot generate is retired, not served.
        if let timeout = clusterPairWarmupTimeoutSeconds {
            let warmup = await Self.runClusterPairWarmup(bridge: bridge, modelID: specification.publicModelID,
                                                         timeoutSeconds: timeout)
            clusterPairWarmup = warmup
            logger.info("Cluster pair warmup canary \(warmup.description)")
            guard clusterPairSlot === handle else { return id }
            guard warmup.succeeded else {
                await retireClusterPairSlot(id, reason: "warmup canary failed: \(warmup.detail ?? "no detail")")
                return id
            }
        }
        refreshClusterMemberAdmission()
        syncWarmModelState()
        startClusterPairCapacityRefresh()
        await refreshClusterPairCapacity()
        logger.info("Cluster pair slot published (\(handle.id.uuidString.prefix(8)))")
        if let client = coordinatorClient { await client.sendEventHeartbeat() }
        return id
    }

    static let readinessLostReason = "pair readiness lost"

    private func requireClusterPairPublication(_ modelID: String) throws {
        guard isClusterMember else { throw ClusterPairSlotError.notServing("solo provider") }
        guard !isShuttingDown, !isDraining, !memberControlRequiresStop else {
            throw ClusterPairSlotError.notServing("member stopping")
        }
        guard clusterPairSlot == nil, modelSlots.isEmpty, !modelsUnloading.contains(modelID) else {
            throw ClusterPairSlotError.notServing("a pair slot is already published or retiring")
        }
        guard loopConfig.models.contains(where: { $0.id == modelID }) else { throw ClusterPairSlotError.unknownModel }
    }

    /// Retire the pair slot: close admission, drain the request in flight,
    /// then shut the bridge, whose engine shuts down the owner. Idempotent; a
    /// call for an older slot id does nothing. Returns whether this call
    /// retired a slot.
    @discardableResult
    func retireClusterPairSlot(_ id: UUID? = nil, reason: String) async -> Bool {
        guard let handle = clusterPairSlot, id == nil || handle.id == id else { return false }
        let modelID = handle.modelID
        guard !modelsUnloading.contains(modelID) else {
            await waitForModelUnload(modelID)
            return false
        }
        modelsUnloading.insert(modelID)
        logger.info("Cluster pair slot retiring (\(handle.id.uuidString.prefix(8))): \(reason)")
        if reason == Self.readinessLostReason {
            // S24: serving ended without being asked to. A planned stop
            // retires the slot first with its own reason and records nothing.
            ClusterObservability.current().record(.init(severity: .error, source: "leader", stateCode: .sessionFailed,
                reason: .peerLost, message: "The pair's readiness was lost while its slot was published (a rank ended or its lease lapsed)",
                jobID: handle.membershipEpoch.uuidString.lowercased(), modelID: modelID))
        }
        clusterPairCapacityTask?.cancel()
        clusterPairCapacityTask = nil
        refreshClusterMemberAdmission()
        syncWarmModelState()
        if let client = coordinatorClient { await client.sendEventHeartbeat() }
        let bridge = modelSlots[modelID]?.engineV2
        await engineV2Runtime.unregister(modelId: modelID)
        // Graceful: a running request finishes unless the pair already lost a
        // rank, in which case the engine has failed it. The engine then shuts
        // the owner down, which ends both ranks' work and lets each owner
        // release its device.
        await bridge?.shutdown()
        if case .clusterPair(let published)? = modelSlots[modelID]?.modelContainer, published === handle {
            modelSlots.removeValue(forKey: modelID)
        }
        if clusterPairSlot === handle { clusterPairSlot = nil }
        modelsUnloading.remove(modelID)
        for waiter in unloadingWaiters.removeValue(forKey: modelID) ?? [] { waiter.resume() }
        refreshClusterMemberAdmission()
        syncWarmModelState()
        await refreshClusterPairCapacity()
        if let client = coordinatorClient { await client.sendEventHeartbeat() }
        logger.info("Cluster pair slot retired (\(handle.id.uuidString.prefix(8)))")
        return true
    }

    /// A stopping member ends its pair session while its control connection
    /// is still open: the pair slot retires (the leader's engine shuts its
    /// owner down once the drained request finished), the member session ends
    /// its owner, and the stop waits, bounded, until the owner released its
    /// device and the session sent its authenticated release receipt. Closing
    /// the connection first left no way for the receipt to arrive: the
    /// coordinator then fenced both devices until the grant lease plus the
    /// owner retirement limit passed (about two minutes on hardware) before
    /// the pair could form again.
    func releaseClusterMemberSessionBeforeClose() async {
        guard isClusterMember else { return }
        await retireClusterPairSlot(reason: "member stopping")
        guard let control = nativePairMemberControl else { return }
        if !(await control.endSessionBeforeClose(timeout: Self.memberSessionReleaseTimeoutSeconds)) {
            logger.warning("Cluster member stopping: the pair session did not release within \(Int(Self.memberSessionReleaseTimeoutSeconds)) s; closing the control connection anyway")
        }
    }
    static let memberSessionReleaseTimeoutSeconds: TimeInterval = 30

    /// The member's capacity: the pair slot's bridge, or no slot. Never a
    /// local memory sample: the pair's memory is on its owners, and a member
    /// refuses solo loads, so it offers no load headroom.
    func refreshClusterPairCapacity() async {
        guard isClusterMember else { return }
        let summary = await engineV2Runtime.capacitySummary(fleetKV: nil)
        let slots = summary.slots.filter { slot in clusterPairSlot.map { slot.model == $0.modelID } ?? false }
        state.backendCapacity = BackendCapacity(slots: slots, gpuMemoryActiveGb: 0,
            gpuMemoryPeakGb: 0, gpuMemoryCacheGb: 0,
            totalMemoryGb: Double(loopConfig.hardware.memoryGb), freeForLoadGb: 0)
        state.inferenceActive = summary.activeRequests > 0
        scheduleEventHeartbeatIfMaterial()
        writeDaemonState()
    }

    /// A member runs no solo capacity monitor; while a pair slot is
    /// published this keeps its slot state (idle / running) current.
    private func startClusterPairCapacityRefresh() {
        clusterPairCapacityTask?.cancel()
        let interval = UInt64(max(1, loopConfig.config.coordinator.heartbeatIntervalSecs / 2)) * 1_000_000_000
        clusterPairCapacityTask = Task { [weak self] in
            while !Task.isCancelled {
                // The nanoseconds overload; see startCapacityRefreshMonitor.
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { break }
                await self?.refreshClusterPairCapacity()
            }
        }
    }
}
