import Foundation
import MLX

struct Gemma4MTPAuxiliaryReceipt: Encodable {
    let policy = "registered_gemma4_mtp_auxiliary_resources_v1"
    let budgetSHA256: String, placement: String
    let completedItems: Int, observationCount: Int, minimumActualFreeBytes: Int
    let maximumActiveBytes: Int, maximumNativePeakBytes: Int
    let constructorUnmaterializedPackedCount: Int
    let constructorObservedActiveBytes: Int
    let liveNativeReserveBytes: Int, liveHostReserveBytes: Int, constructorReserveBytes: Int
    let verificationNativeReserveBytes: Int
    let logicalSnapshotBytes: Int
    let servingFloorChanged = false, reclaimableUsedForAdmission = false
    let wholeProcessPeakBoundEstablished = false, physicalOwnerRetirementEstablished = false
}

/// An additive resource ledger under the ORIGINAL native owner. It creates no
/// device, lease, process or request state. Local use is attached to the target
/// owner; remote use samples the same physical policy directly. No read is
/// admitted by separately taking max(targetRequirement, auxiliaryRequirement).
final class Gemma4MTPAuxiliaryOwner {
    struct Reservation {
        let revision: Int, nativeBytes: Int, hostBytes: Int
    }
    private enum Phase: Equatable { case source, constructing, assistantLoading, embeddingLoading, ready, complete, failed }
    let budget: Gemma4MTPAuxiliaryBudget
    let deadline: UInt64
    private var phase = Phase.source
    private var primaryAttached = false
    private var completed = 0, pending: Int?, revision = 0, observedRevision = -1
    private var observations = 0, minimumFree = Int.max, maximumActive = 0, maximumPeak = 0
    private var lazyPacked = 0, constructorActive = 0
    private var verificationBounds: [String:Int] = [:]
    private var verificationBytes = 0

    init(budget: Gemma4MTPAuxiliaryBudget, deadline: UInt64) throws {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline > now, deadline-now <= 300_000_000_000 else { throw ProbeError("Assistant needs the existing bounded native deadline") }
        guard try budget.items.map({ try QwenResidentResourceEnvironment.allocationBound($0.bytes) }) == budget.itemBounds,
              try (budget.constructorTerms+budget.liveTerms).allSatisfy({
                  try QwenResidentResourceEnvironment.allocationBound($0.logicalBytes) == $0.allocationBound
              }) else { throw ProbeError("Assistant budget did not use this actual native allocator bound") }
        self.budget = budget; self.deadline = deadline
    }
    func requireLive() throws {
        guard phase != .failed, DispatchTime.now().uptimeNanoseconds < deadline else {
            throw ProbeError("Assistant auxiliary scope failed or expired")
        }
    }
    func attachToPrimary(deadline: UInt64, requestSHA256: String) throws {
        guard phase == .source, !primaryAttached, budget.placement == .localTarget,
              self.deadline == deadline, budget.requestSHA256 == requestSHA256 else {
            throw ProbeError("Assistant auxiliary target attachment differs")
        }
        primaryAttached = true; advanceRevision()
    }
    func reservation() throws -> Reservation {
        try requireLive()
        let loading = phase == .source || phase == .constructing || phase == .assistantLoading || phase == .embeddingLoading
        let remaining = loading ? try QwenLongPrefillCheckedBytes.sum(Array(budget.itemBounds.dropFirst(completed))) : 0
        let unread = loading ? Array(budget.items.dropFirst(completed)) : []
        let host = unread.map(\.bytes).max() ?? 0
        let copy = loading ? Array(budget.itemBounds.dropFirst(completed)).max() ?? 0 : 0
        let scratch = unread.isEmpty ? 0 : CheckpointAlignedReadPlan.maximumScratchAllocationBytes
        let constructor = phase == .source || phase == .constructing || phase == .assistantLoading ? budget.constructorBytes : 0
        return .init(revision:revision,
            nativeBytes:try QwenLongPrefillCheckedBytes.sum([remaining,copy,constructor,budget.liveNativeBytes,verificationBytes]),
            hostBytes:try QwenLongPrefillCheckedBytes.sum([host,scratch,budget.liveHostBytes]))
    }
    /// Called ONLY after the primary owner's SUMMED inequalities pass on the
    /// same fresh actual observations, or by checkStandalone below.
    func acceptedObservation(_ reservation: Reservation, os: QwenDenseStageLoadOSObservation,
                             native: QwenDenseStageLoadNativeObservation) throws {
        try requireLive()
        guard reservation.revision == revision, os.pressureLevel == 1,
              budget.placement == .remoteAssistant || primaryAttached else {
            throw ProbeError("Assistant observation is stale or detached from primary admission")
        }
        observations = try QwenLongPrefillCheckedBytes.sum([observations,1])
        minimumFree = min(minimumFree,os.actualFreeBytes); maximumActive = max(maximumActive,native.activeBytes)
        maximumPeak = max(maximumPeak,native.peakBytes); observedRevision = revision
    }
    func requireObserved() throws {
        try requireLive()
        guard observedRevision == revision else { throw ProbeError("Assistant phase lacks its actual current resource gate") }
    }
    func checkStandalone() throws {
        do {
            guard budget.placement == .remoteAssistant, !primaryAttached else {
                throw ProbeError("Local assistant must use the combined target resource inequality")
            }
            let value = try reservation()
            let os = try QwenResidentResourceEnvironment.observe()
            let native = QwenDenseStageLoadResources.observeNative()
            guard os.pressureLevel == 1, native.activeBytes >= 0, native.cacheBytes == 0,
                  native.peakBytes >= native.activeBytes, native.allocatorLimitBytes > 0 else {
                throw ProbeError("Assistant requires normal pressure, zero native cache and valid allocator")
            }
            let sum = QwenLongPrefillCheckedBytes.sum
            let free = max(QwenDenseStageLoadPolicy.minimumActualFreeBytes,
                try sum([value.nativeBytes,value.hostBytes,QwenDenseStageLoadPolicy.loadingHeadroomBytes]))
            let allocator = try sum([native.activeBytes,native.cacheBytes,value.nativeBytes,QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
            guard os.actualFreeBytes >= free, os.physicalMemoryBytes >= free, native.allocatorLimitBytes >= allocator else {
                throw ProbeError("Assistant auxiliary resources refused: completed=\(completed)/\(budget.items.count), actualFree=\(os.actualFreeBytes), requiredFree=\(free), active=\(native.activeBytes), requiredAllocator=\(allocator)")
            }
            try acceptedObservation(value,os:os,native:native)
        } catch { poison(); throw error }
    }
    func beginConstruction() throws {
        try requireObserved()
        guard phase == .source else { throw ProbeError("Assistant construction is out of order") }
        phase = .constructing; advanceRevision()
    }
    func prepared(unmaterializedPackedCount: Int) throws {
        try requireObserved()
        guard phase == .constructing, unmaterializedPackedCount == 69 else {
            throw ProbeError("Assistant constructor did not prove 23 lazy quantized triplets")
        }
        lazyPacked = unmaterializedPackedCount; constructorActive = Memory.activeMemory
        phase = .assistantLoading; advanceRevision()
    }
    func beforeItem(source: String, name: String, shape: [Int], bytes: Int) throws {
        try requireObserved()
        guard (phase == .assistantLoading && source == "assistant") || (phase == .embeddingLoading && source == "targetEmbedding"),
              pending == nil, budget.items.indices.contains(completed),
              budget.items[completed] == .init(source:source,name:name,shape:shape,bytes:bytes) else {
            throw ProbeError("Assistant read is not its exact next admitted tensor")
        }
        pending = completed; advanceRevision()
    }
    func afterItem(source: String, name: String) throws {
        try requireObserved()
        guard pending == completed, budget.items.indices.contains(completed),
              budget.items[completed].source == source, budget.items[completed].name == name else {
            throw ProbeError("Assistant read completion is replayed or out of order")
        }
        completed += 1; pending = nil; advanceRevision()
    }
    func assistantLoaded(_ receipt: Gemma4AssistantLoadReceipt) throws {
        try requireObserved()
        guard phase == .assistantLoading, completed == 94, pending == nil,
              receipt.artifactSHA256 == Gemma4AssistantArtifact.aggregateSHA256,
              receipt.configurationSHA256 == Gemma4AssistantArtifact.configSHA256,
              receipt.tensorCount == 94, receipt.tensorBytes == 236_114_440,
              receipt.readAccounting.selectedBytes == receipt.tensorBytes else {
            throw ProbeError("Assistant actual load receipt differs")
        }
        phase = budget.placement == .remoteAssistant ? .embeddingLoading : .ready
        advanceRevision()
    }
    func beforeEmbedding(_ item: Gemma4SelectedTensor) throws {
        try beforeItem(source:"targetEmbedding",name:item.localName,shape:item.source.layout.shape,bytes:item.source.layout.byteCount)
    }
    func afterEmbedding(_ item: Gemma4SelectedTensor) throws { try afterItem(source:"targetEmbedding",name:item.localName) }
    func embeddingLoaded(_ receipt: Gemma4DraftEmbeddingLoadReceipt) throws {
        try requireObserved()
        guard phase == .embeddingLoading, completed == 97, pending == nil,
              receipt.artifactSHA256 == Gemma4ArtifactMetadata.artifactAggregateSHA256,
              receipt.configurationSHA256 == Gemma4ArtifactMetadata.configurationSHA256,
              receipt.loadedTensorBytes == 415_236_096, receipt.selectedTensorCount == 3,
              receipt.readAccounting.selectedBytes == receipt.loadedTensorBytes else {
            throw ProbeError("Assistant selected target embedding completion differs")
        }
        phase = .ready; advanceRevision()
    }
    func admitVerification(_ plan: CBv2AttentionVerificationPlan) throws {
        try requireObserved()
        guard phase == .ready, primaryAttached, budget.placement == .localTarget,
              plan.layout.layers.count == 30, plan.layout.layers.map(\.globalIndex) == Array(0..<30),
              plan.layout.maximumTokens == budget.maximumFrontier+1,
              Set(plan.captureLayerIndices) == [28,29], (1...4).contains(plan.steps) else {
            throw ProbeError("Assistant target verification plan differs from its original target owner")
        }
        var next = verificationBounds
        // Invocation-local scalar reuse; each named array remains separately charged.
        var allocationBounds = InvocationAllocationBoundMemo()
        for item in plan.additionalArrays {
            let bound = try allocationBounds.value(for:item.bytes,
                resolve:QwenResidentResourceEnvironment.allocationBound)
            next[item.name] = max(next[item.name] ?? 0,bound)
        }
        let total = try QwenLongPrefillCheckedBytes.sum(Array(next.values))
        verificationBounds = next; verificationBytes = total; advanceRevision()
        // Never retire these addends on reconcile: old assistant conditioning,
        // new capture, window commit copies and outer logits/hidden may overlap.
        // The ORIGINAL owner must check this new revision before any state work.
    }
    func requireGrant(count: Int, capture: Gemma4OwnedMTPConditioning) throws {
        try requireObserved()
        let arrays = [capture.fullKeys,capture.fullValues,capture.slidingKeys,capture.slidingValues]
        guard phase == .ready, (1...2).contains(count), (1...budget.maximumFrontier).contains(capture.frontier),
              arrays.allSatisfy({ $0.dtype == .bfloat16 }),
              capture.fullKeys.shape == [1,2,capture.frontier,512], capture.fullValues.shape == capture.fullKeys.shape,
              capture.slidingKeys.shape == [1,8,min(capture.frontier,1024),256],
              capture.slidingValues.shape == capture.slidingKeys.shape,
              capture.hidden.shape == [1,1,2816], [.float16,.bfloat16,.float32].contains(capture.hidden.dtype) else {
            throw ProbeError("Assistant grant exceeds admitted depth or actual conditioning geometry/type")
        }
        // Exact outstanding credit and request/epoch/branch identity remain the
        // serialized AsyncMTPProposalLedger's job. All five graph slots stay charged.
    }
    func completedAfterNativeFence(check: () throws -> Void) throws -> Gemma4MTPAuxiliaryReceipt {
        guard phase == .ready, completed == budget.items.count, pending == nil else { throw ProbeError("Assistant auxiliary load is incomplete") }
        Stream.gpu.synchronize(); Stream.cpu.synchronize(); try check(); try requireObserved()
        phase = .complete
        // Keep live terms charged even here. The original parent controls actual
        // arrays, transfer leases and unload; this receipt does not release them.
        return .init(budgetSHA256:budget.fingerprint,placement:budget.placement.rawValue,
            completedItems:completed,observationCount:observations,minimumActualFreeBytes:minimumFree,
            maximumActiveBytes:maximumActive,maximumNativePeakBytes:maximumPeak,
            constructorUnmaterializedPackedCount:lazyPacked,constructorObservedActiveBytes:constructorActive,
            liveNativeReserveBytes:budget.liveNativeBytes,liveHostReserveBytes:budget.liveHostBytes,
            constructorReserveBytes:budget.constructorBytes,verificationNativeReserveBytes:verificationBytes,
            logicalSnapshotBytes:budget.snapshotLogicalBytes)
    }
    func poison() { phase = .failed }
    private func advanceRevision() { revision += 1; observedRevision = -1 }
}
