import Foundation
import MLXLMCommon
import MLXVLM

/// Root's bridge seam throws only these ownership outcomes. failedCompletion
/// carries an allowlisted code, never reflected native/payload/path error text.
enum MiMoV26NativeBridgeShutdownError: Error, Sendable {
    case pendingConsumers
    case failedCompletion(String)
    case identityMismatch
}

enum MiMoV26NativeTransactionError: Error, Equatable, Sendable {
    case unknownLifecycle, lifecycleClosed, processFaulted, invalidLifecycle
    case foreignOwner, unsupportedExecutionContract, pendingWork, warmRebuildUnsupported
    case slotAssemblyAlreadyClaimed
}

/// Actual host lifecycle, not a model authorization bypass. Stop closes a
/// generation before any final publication; restart needs a fresh open token.
struct MiMoV26NativeLifecycle: Hashable, Sendable {
    fileprivate let registryID: UUID
    fileprivate let id: UUID
    let generation: UInt64
}

enum MiMoV26NativeRetirementPending: String, Sendable {
    case activeOperations, ownedTasks, constructionActive, containerAdoption
    case engineProofUnavailable, hostConsumers, identityMismatch, alreadyDraining
    case permitSettlement, registryUnavailable, wiredResidencySettlement
}
struct MiMoV26NativeRetirementReceipt: Sendable {
    let transactionID, sessionID: UUID
    let audioSessionID: UUID?
    let lifecycle: MiMoV26NativeLifecycle
    let construction: NativeConstructionReceipt
    let engine: CBv2NativeShutdownReceipt?
    fileprivate init(transactionID: UUID, sessionID: UUID, lifecycle: MiMoV26NativeLifecycle,
                     construction: NativeConstructionReceipt, engine: CBv2NativeShutdownReceipt?,
                     audioSessionID: UUID? = nil) {
        self.transactionID = transactionID; self.sessionID = sessionID; self.lifecycle = lifecycle
        self.construction = construction; self.engine = engine
        self.audioSessionID = audioSessionID
    }
}
enum MiMoV26NativeRetirement: Sendable {
    case notClaimed
    case retired(MiMoV26NativeRetirementReceipt)
    case pending(MiMoV26NativeRetirementPending)
    case retainedFault(code: String)
}

/// Process-lifetime strong ownership. The production singleton never forgets a
/// failed native owner. Tests may use an isolated registry but must retain it
/// through every active/faulted operation. There is no reset/fault recovery API.
final class MiMoV26NativeLoadRegistry: @unchecked Sendable {
    static let shared = MiMoV26NativeLoadRegistry()

    private protocol OwnedTask: Sendable {
        func cancel()
        func join() async
    }
    private struct TaskOwner<Success: Sendable>: OwnedTask {
        let task: Task<Success, Error>
        func cancel() { task.cancel() }
        func join() async { _ = await task.result }
    }
    private struct Lifetime { var generation: UInt64; var open: Bool }
    private final class Entry {
        let transaction: MiMoV26NativeLoadTransaction
        var tasks: [UUID: any OwnedTask] = [:]
        init(_ transaction: MiMoV26NativeLoadTransaction) { self.transaction = transaction }
    }
    private let id = UUID()
    private let lock = NSLock()
    private var lifetimes: [UUID: Lifetime] = [:]
    private var entries: [UUID: Entry] = [:]
    private var faults: [UUID: String] = [:]

    func openLifecycle() throws -> MiMoV26NativeLifecycle {
        try lock.withLock {
            guard faults.isEmpty else { throw MiMoV26NativeTransactionError.processFaulted }
            let key = UUID(); lifetimes[key] = .init(generation: 1, open: true)
            return .init(registryID: id, id: key, generation: 1)
        }
    }
    /// Cancellation is not a permanent fault. Already active work keeps its
    /// owners and charge until actual completion, even after this returns.
    @discardableResult
    func closeLifecycle(_ token: MiMoV26NativeLifecycle) throws -> MiMoV26NativeLifecycle {
        let result: (MiMoV26NativeLifecycle, [any OwnedTask]) = try lock.withLock {
            guard token.registryID == id, let current = lifetimes[token.id],
                  current.generation == token.generation else { throw MiMoV26NativeTransactionError.unknownLifecycle }
            let next = current.generation.addingReportingOverflow(1)
            guard !next.overflow else { throw MiMoV26NativeTransactionError.invalidLifecycle }
            lifetimes[token.id] = .init(generation: next.partialValue, open: false)
            var tasks: [any OwnedTask] = []
            for entry in entries.values where entry.transaction.lifecycle.id == token.id {
                entry.transaction.cancelFromRegistry()
                tasks += entry.tasks.values
            }
            return (.init(registryID: id, id: token.id, generation: next.partialValue), tasks)
        }
        // Task cancellation handlers can reenter the registry. Never run them
        // while holding its lock.
        for task in result.1 { task.cancel() }
        return result.0
    }
    func reopenLifecycle(_ closed: MiMoV26NativeLifecycle) throws -> MiMoV26NativeLifecycle {
        try lock.withLock {
            guard faults.isEmpty else { throw MiMoV26NativeTransactionError.processFaulted }
            guard closed.registryID == id, let current = lifetimes[closed.id],
                  !current.open, current.generation == closed.generation else {
                throw MiMoV26NativeTransactionError.unknownLifecycle
            }
            guard !entries.values.contains(where: { $0.transaction.lifecycle.id == closed.id }) else {
                throw MiMoV26NativeTransactionError.pendingWork
            }
            let next = current.generation.addingReportingOverflow(1)
            guard !next.overflow else { throw MiMoV26NativeTransactionError.invalidLifecycle }
            lifetimes[closed.id] = .init(generation: next.partialValue, open: true)
            return .init(registryID: id, id: closed.id, generation: next.partialValue)
        }
    }
    func requireNewNativeWorkAllowed() throws {
        try lock.withLock {
            guard faults.isEmpty else { throw MiMoV26NativeTransactionError.processFaulted }
        }
    }
    private func requireOpen(_ token: MiMoV26NativeLifecycle) throws {
        guard faults.isEmpty else { throw MiMoV26NativeTransactionError.processFaulted }
        guard token.registryID == id, let current = lifetimes[token.id] else {
            throw MiMoV26NativeTransactionError.unknownLifecycle
        }
        guard current.open, current.generation == token.generation else {
            throw MiMoV26NativeTransactionError.lifecycleClosed
        }
    }
    func install(request: MiMoV26SerialLoadRequest, budget: GlobalKVCacheBudget,
                 lifecycle: MiMoV26NativeLifecycle) throws -> MiMoV26NativeLoadTransaction {
        try lock.withLock {
            try requireOpen(lifecycle)
            let transaction = MiMoV26NativeLoadTransaction(request: request, budget: budget,
                                                          lifecycle: lifecycle, registry: self)
            entries[transaction.id] = Entry(transaction)
            return transaction
        }
    }
    fileprivate func withEntry<Result>(_ transaction: MiMoV26NativeLoadTransaction, newWork: Bool,
                                       _ body: () throws -> Result) throws -> Result {
        try lock.withLock {
            guard entries[transaction.id]?.transaction === transaction else {
                throw MiMoV26NativeTransactionError.foreignOwner
            }
            if newWork { try requireOpen(transaction.lifecycle) }
            return try body()
        }
    }
    func cancel(_ transaction: MiMoV26NativeLoadTransaction) {
        let tasks: [any OwnedTask] = lock.withLock {
            guard let entry = entries[transaction.id], entry.transaction === transaction else { return [] }
            guard entry.transaction.cancelFromRegistry() else { return [] }
            return Array(entry.tasks.values)
        }
        for task in tasks { task.cancel() }
    }
    fileprivate func retainFault(_ transaction: MiMoV26NativeLoadTransaction, code: String) {
        let tasks: [any OwnedTask] = lock.withLock {
            guard entries[transaction.id]?.transaction === transaction else { return [] }
            faults[transaction.id] = code
            transaction.faultFromRegistry(code)
            var tasks: [any OwnedTask] = []
            for entry in entries.values {
                entry.transaction.cancelFromRegistry()
                tasks += entry.tasks.values
            }
            return tasks
        }
        for task in tasks { task.cancel() }
    }
    fileprivate func removeRetired(_ transaction: MiMoV26NativeLoadTransaction) {
        lock.withLock {
            guard let entry = entries[transaction.id], entry.transaction === transaction,
                  entry.tasks.isEmpty, transaction.retirementReceipt != nil else { return }
            entries.removeValue(forKey: transaction.id)
        }
    }
    fileprivate func taskCount(_ transaction: MiMoV26NativeLoadTransaction) -> Int {
        lock.withLock { entries[transaction.id]?.tasks.count ?? 0 }
    }

    /// Task handle belongs to the registry entry, NEVER to its transaction.
    /// Complete only after the actual Task.result, not a caller "done" Boolean.
    func launchOwnedTask<Success: Sendable>(
        for transaction: MiMoV26NativeLoadTransaction,
        _ operation: @escaping @Sendable () async throws -> Success
    ) throws -> Task<Success, Error> {
        let taskID = UUID()
        let task: Task<Success, Error> = try lock.withLock {
            try requireOpen(transaction.lifecycle)
            guard let entry = entries[transaction.id], entry.transaction === transaction else {
                throw MiMoV26NativeTransactionError.foreignOwner
            }
            try transaction.requireTaskLaunchFromRegistry()
            let task = Task { try await operation() }
            entry.tasks[taskID] = TaskOwner(task: task)
            return task
        }
        Task { [weak self] in
            _ = await task.result
            self?.completedTask(transactionID: transaction.id, taskID: taskID)
        }
        return task
    }
    private func completedTask(transactionID: UUID, taskID: UUID) {
        lock.withLock { _ = entries[transactionID]?.tasks.removeValue(forKey: taskID) }
    }
    /// For an EXTERNAL control task only, never from one of this entry's own
    /// tasks. Retirement itself does not self-await; it reports .ownedTasks.
    func joinOwnedTasksFromOutside(_ transaction: MiMoV26NativeLoadTransaction) async {
        let tasks = lock.withLock { entries[transaction.id]?.tasks ?? [:] }
        for (id, task) in tasks {
            await task.join()
            completedTask(transactionID: transaction.id, taskID: id)
        }
    }
    var hasRetainedFault: Bool { lock.withLock { !faults.isEmpty } }
    /// Refusal fact for reclaim/regrow, never a completion or memory-credit
    /// grant. Publication sealing's temporary draining flag is not closing.
    var hasUnretiredClosingTransactions: Bool {
        lock.withLock { entries.values.contains { $0.transaction.isUnretiredClosingFromRegistry } }
    }
    var retainedTransactionIDs: [UUID] { lock.withLock { Array(entries.keys) } }
    func transaction(_ id: UUID) -> MiMoV26NativeLoadTransaction? {
        lock.withLock { entries[id]?.transaction }
    }
}

/// No raw model/binding/array crosses this host object. All cross-task handles
/// already have real synchronization. Lock order: registry -> transaction ->
/// permit/ledger. Never call registry while holding transaction.lock.
final class MiMoV26NativeLoadTransaction: @unchecked Sendable {
    enum Phase: String, Sendable { case registered, preparing, building, ready, published, cancelling, draining, retired, retainedFault }
    struct Snapshot: Sendable {
        let id, sessionID: UUID
        let lifecycleGeneration: UInt64
        let phase: Phase
        let activeOperations: Int
        let hasContainer, hasAssistant, hasEngine, hasBridge, hasBundle: Bool
        let constructionEpoch: UInt64
        let constructionPhase: NativeConstructionPhase
        let constructionFailed: Bool
        let faultCode: String?
        let permit: MiMoV26PendingLoadReservation.Snapshot?
        let audioSessionID: UUID?
        let audioChargedBytes: UInt64
        let hasInstalledAudioReceipt, audioAliasesDetached: Bool
    }
    let id = UUID()
    let request: MiMoV26SerialLoadRequest
    let lifecycle: MiMoV26NativeLifecycle
    let budget: GlobalKVCacheBudget
    private weak var registry: MiMoV26NativeLoadRegistry?
    private let work = NativeConstructionWork()
    private let lock = NSLock()
    private var permit: MiMoV26PendingLoadReservation?
    private var audioRequest: MiMoV26AudioSidecarLoadRequest?
    private var audioReservation: MiMoV26AudioSidecarReservation?
    private var audioReceipt: MiMoV26AudioSidecarLoadReceipt?
    private var audioClaim: UUID?
    private var audioAliasesDetached = false
    private var container: ModelContainer?
    private var adopted = false
    private var assistant: ProviderMTPAssistantHandle?
    private var engine: EngineV2?
    private var contract: CBv2NativeExecutionContract?
    private var bridge: EngineV2Bridge?
    // The actual returned bundle is an owner: its deinit releases its assistant
    // handle. Retaining only that same handle does not stop destructive deinit.
    private var bundle: ProviderEngineBundle?
    private var operations = Set<UUID>()
    private var mediaReservations: [UUID: MiMoV26ManagedMediaReservation] = [:]
    private var mediaConsumers: [UUID: NativeLocalConsumerLease] = [:]
    private weak var decodedMediaFacade: MiMoV26ServingLoad?
    private var decodedVideoSampling: MiMoV26EncodedVisualDecoder.Sampling?
    private final class MediaCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func cancel() { lock.withLock { value = true } }
        var isCancelled: Bool { lock.withLock { value } }
    }
    private var permitPreparation: UUID?
    private var nativeConstruction: UUID?
    private var slotAssemblyClaimed = false
    private var usageReaderPreparationHookForTesting: (@Sendable () -> Void)?
    private var cancelled = false
    private var published = false
    private var draining = false
    private var faultCode: String?
    private var sealed: NativeConstructionReceipt?
    private var retired: MiMoV26NativeRetirementReceipt?
    private var completedEngineReceipt: CBv2NativeShutdownReceipt?
    private var wiredResidency: MiMoV26WiredResidency?
    private var nativePrefixResources: MiMoV26NativePrefixResources?
    private var prefixAliasesDetached = false

    fileprivate init(request: MiMoV26SerialLoadRequest, budget: GlobalKVCacheBudget,
                     lifecycle: MiMoV26NativeLifecycle, registry: MiMoV26NativeLoadRegistry) {
        self.request = request; self.budget = budget; self.lifecycle = lifecycle; self.registry = registry
    }
    private func registered<Result>(newWork: Bool, _ body: () throws -> Result) throws -> Result {
        guard let registry else { throw MiMoV26NativeTransactionError.invalidLifecycle }
        return try registry.withEntry(self, newWork: newWork, body)
    }
    func claimPermit() throws {
        let preparation: (UUID, (@Sendable () -> Void)?) = try registered(newWork: true) {
            try lock.withLock {
                guard permit == nil, !cancelled, !published, !draining,
                      retired == nil, faultCode == nil, sealed == nil else {
                    throw MiMoV26NativeTransactionError.invalidLifecycle
                }
                guard permitPreparation == nil else { throw MiMoV26NativeTransactionError.pendingWork }
                let id = UUID(); permitPreparation = id; operations.insert(id)
                let hook = usageReaderPreparationHookForTesting
                usageReaderPreparationHookForTesting = nil
                return (id, hook)
            }
        }
        defer { endExclusiveOperation(preparation.0, permitPreparation: true) }
        // The production reader's first call can create the allocator/device.
        // Hold the registered transaction/operation, NOT registry or TX locks.
        // Subsequent constructor/ledger checks reuse the prepared once-only
        // production reader; no native initialization occurs under host locks.
        preparation.1?()
        budget.processLedger.prepareUsageReader()
        try registered(newWork: true) {
            try lock.withLock {
                guard permitPreparation == preparation.0, operations.contains(preparation.0),
                      permit == nil, !cancelled, retired == nil, !published,
                      !draining, faultCode == nil, sealed == nil else {
                    throw MiMoV26NativeTransactionError.invalidLifecycle
                }
                permit = try budget.reserveMiMoV26PendingLoad(for: request)
            }
        }
    }
    /// One-shot observation/hold immediately before the REAL reader call, with
    /// no intervening lock. Test-only; it cannot substitute a successful reader.
    func setUsageReaderPreparationHookForTesting(_ hook: (@Sendable () -> Void)?) {
        lock.withLock { usageReaderPreparationHookForTesting = hook }
    }

    /// One real separate sidecar charge in the SAME process ledger. The live
    /// exclusive operation prevents retirement while out-of-lock admission
    /// owns a future result. No native/model/session alias enters this object.
    func claimAudioSidecar(request audio: MiMoV26AudioSidecarLoadRequest,
        policy: MiMoV26ServingLoad.DecodedAudioPolicy) throws {
        let claim: UUID = try registered(newWork: true) {
            try lock.withLock {
                guard permit != nil, !cancelled, !published, !draining, retired == nil,
                      sealed == nil, faultCode == nil, audioRequest == nil,
                      audioReservation == nil, audioClaim == nil,
                      audio.canonicalRoot == request.binding.canonicalRoot,
                      audio.mainConfigurationSHA256 == request.binding.configSHA256 else {
                    throw MiMoV26NativeTransactionError.invalidLifecycle
                }
                let id = UUID(); audioClaim = id; operations.insert(id); audioRequest = audio
                return id
            }
        }
        defer {
            lock.withLock {
                if audioClaim == claim { audioClaim = nil; operations.remove(claim) }
            }
            if work.snapshot.isRetainedFault { registry?.retainFault(self, code: "construction_completion_failed") }
        }
        // The real usage-reader/ledger admission occurs outside registry/TX
        // locks. Its constructor rolls back only an exact empty cold owner.
        let admitted = try MiMoV26AudioSidecarReservation(request: audio,
            maximumBytes: policy.maximumSidecarReservationBytes,
            additionalSystemReserveBytes: policy.additionalSystemReserveBytes,
            ledger: budget.processLedger)
        // Transfer BEFORE any late liveness veto. The
        // exclusive operation makes these identity checks invariant, not a
        // second independently mutable ownership marker.
        lock.withLock {
            precondition(audioClaim == claim && audioReservation == nil)
            audioReservation = admitted
            if faultCode != nil { admitted.markRetainedFault() }
            else if cancelled { admitted.revoke() }
        }
        try registered(newWork: true) {
            try lock.withLock {
                guard audioClaim == claim, audioReservation === admitted,
                      !cancelled, !published, !draining, retired == nil, faultCode == nil else {
                    throw MiMoV26NativeTransactionError.invalidLifecycle
                }
            }
        }
        try admitted.validateActive()
    }
    func audioReservationForInstallation(_ expected: MiMoV26AudioSidecarLoadRequest) throws
        -> MiMoV26AudioSidecarReservation {
        let value = try registered(newWork: true) {
            try lock.withLock {
                guard !cancelled, !published, !draining, retired == nil, faultCode == nil,
                      audioRequest == expected, audioReceipt == nil, let audioReservation,
                      audioReservation.request == expected else { throw MiMoV26NativeTransactionError.foreignOwner }
                return audioReservation
            }
        }
        try value.validateActive()
        return value
    }
    func registerInstalledAudioReceipt(_ receipt: MiMoV26AudioSidecarLoadReceipt) throws {
        try registered(newWork: false) {
            try lock.withLock {
                guard nativeConstruction != nil, !operations.isEmpty, !draining, retired == nil,
                      audioRequest == receipt.request, let audioReservation,
                      audioReservation.request == receipt.request, audioReceipt == nil,
                      receipt.sourceIdentity == receipt.request.payloadSHA256 else {
                    throw MiMoV26NativeTransactionError.foreignOwner
                }
                audioReceipt = receipt // capture despite a late stop/fault
                if faultCode != nil { audioReservation.markRetainedFault() }
                else if cancelled { audioReservation.revoke() }
            }
        }
    }
    private func matchesAudioContract(_ contract: CBv2NativeExecutionContract) -> Bool {
        guard contract.supportsDecodedAudioMedia else { return audioRequest == nil }
        guard let receipt = audioReceipt, audioReservation?.request == receipt.request else { return false }
        return contract.audioSidecarSessionID == receipt.request.sessionID
            && contract.audioSidecarSourceIdentity == receipt.sourceIdentity
            && contract.audioSidecarGeneration == receipt.codecGeneration
    }

    /// Actual retained FD/codec/load permit validation through the serialized
    /// model, before publication sealing. The registered operation spans await.
    func validateAudioOwnerForSetup() async throws {
        guard let expected = lock.withLock({ audioRequest }) else { return }
        let operation = try beginOperation()
        defer { endOperation(operation) }
        let owner = try lock.withLock { () throws -> ModelContainer in
            guard let container, audioReceipt != nil else { throw MiMoV26NativeTransactionError.pendingWork }
            return container
        }
        do {
            let actual = try await owner.perform { context in
                try self.recheckSetup()
                guard let model = context.model as? MiMoV26LoadedModel else {
                    throw MiMoV26NativeTransactionError.foreignOwner
                }
                return try model.validateInstalledAudioSidecar(expectedRequest: expected)
            }
            try recheckSetup()
            guard lock.withLock({ audioReceipt?.codecGeneration == actual.codecGeneration
                && audioReceipt?.request == actual.request }) else {
                throw MiMoV26NativeTransactionError.foreignOwner
            }
        } catch is CancellationError { throw CancellationError() }
        catch MiMoV26MultimodalError.reservationRejected { throw MiMoV26MultimodalError.reservationRejected }
        catch {
            if error as? MiMoV26AudioSidecarError == .invalidatedOwner, isCancellationRequested {
                throw CancellationError()
            }
            registry?.retainFault(self, code: "audio_owner_validation_failed")
            throw error
        }
    }
    @discardableResult
    fileprivate func cancelFromRegistry() -> Bool {
        lock.withLock {
            let first = !cancelled
            cancelled = true; permit?.revoke(); audioReservation?.revoke()
            return first
        }
    }
    fileprivate func faultFromRegistry(_ code: String) {
        lock.withLock {
            cancelled = true; faultCode = code; permit?.revoke()
            audioReservation?.markRetainedFault()
        }
    }
    func revoke() { registry?.cancel(self) }
    fileprivate func requireTaskLaunchFromRegistry() throws {
        try lock.withLock {
            guard !cancelled, !published, !draining, retired == nil, faultCode == nil,
                  sealed == nil, permit != nil else { throw MiMoV26NativeTransactionError.invalidLifecycle }
        }
    }
    var isCancellationRequested: Bool { lock.withLock { cancelled || faultCode != nil || retired != nil } }
    fileprivate var retirementReceipt: MiMoV26NativeRetirementReceipt? { lock.withLock { retired } }
    /// Actual retained actor for an external retirement-progress observer. This
    /// is no receipt, mutation permission, consumer join or memory credit.
    func registeredBridgeForRetirement() -> EngineV2Bridge? { lock.withLock { bridge } }
    /// Identity only, including a closing owner. This grants no liveness,
    /// admission, native readiness or retirement authority.
    func matchesAcquisitionOwner(_ acquisition: MultiModelBatchSchedulerEngine.AcquiredModel) -> Bool {
        guard let candidate = acquisition.container,
              let candidateBridge = acquisition.engineV2Bridge else { return false }
        return lock.withLock { container === candidate && bridge === candidateBridge }
    }
    fileprivate var isUnretiredClosingFromRegistry: Bool {
        lock.withLock {
            guard retired == nil else { return false }
            return cancelled || faultCode != nil || permit?.snapshot().lifecycle == .revoked
        }
    }

    func recheckSetup() throws {
        try registered(newWork: true) {
            try lock.withLock {
                guard !published else { throw MiMoV26NativeTransactionError.warmRebuildUnsupported }
                guard !cancelled else { throw CancellationError() }
                guard !draining, retired == nil, faultCode == nil, let permit else {
                    throw MiMoV26NativeTransactionError.invalidLifecycle
                }
                try permit.recheck(for: request)
            }
        }
    }
    /// Root's published native submission gate. Other host entrypoints also
    /// consult registry.requireNewNativeWorkAllowed() after a process fault.
    func requireServingWorkAllowed() throws {
        try registered(newWork: true) {
            try lock.withLock {
                guard published, !cancelled, !draining, retired == nil, faultCode == nil else {
                    throw MiMoV26NativeTransactionError.invalidLifecycle
                }
            }
        }
    }
    private func beginOperation() throws -> UUID {
        try registered(newWork: true) {
            try lock.withLock {
                guard !cancelled else { throw CancellationError() }
                guard !published, !draining, retired == nil, faultCode == nil,
                      sealed == nil, permit != nil else { throw MiMoV26NativeTransactionError.invalidLifecycle }
                let id = UUID(); operations.insert(id); return id
            }
        }
    }
    private func endOperation(_ id: UUID) {
        lock.withLock { _ = operations.remove(id) }
        if work.snapshot.isRetainedFault {
            registry?.retainFault(self, code: "construction_completion_failed")
        }
    }
    private func endExclusiveOperation(_ id: UUID, permitPreparation isPermit: Bool = false) {
        lock.withLock {
            if isPermit {
                guard permitPreparation == id else { return }
                permitPreparation = nil
            } else {
                guard nativeConstruction == id else { return }
                nativeConstruction = nil
            }
            operations.remove(id)
        }
        if work.snapshot.isRetainedFault {
            registry?.retainFault(self, code: "construction_completion_failed")
        }
    }

    /// Root wraps its complete awaited setup, including post-engine configure/
    /// vetoes. Cancellation keeps this operation live until the body unwinds.
    func performSetup<Result: Sendable>(
        _ body: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        let operation = try beginOperation()
        defer { endOperation(operation) }
        do {
            let result = try await body()
            try recheckSetup()
            return result
        } catch MiMoV26NativeTransactionError.slotAssemblyAlreadyClaimed {
            // An outer setup wrapper can contain a factory whose one-shot
            // admission refuses a duplicate. That rejected invocation owns no
            // new pipeline and must not revoke the existing one.
            throw MiMoV26NativeTransactionError.slotAssemblyAlreadyClaimed
        } catch {
            revoke()
            throw error
        }
    }

    func loadContainer(session: consuming MiMoV26SerialLoadSession,
                       prepared: MiMoV26ModelFactory.Prepared) async throws -> ModelContainer {
        let operation = try beginOperation()
        defer { endOperation(operation) }
        let held = try lock.withLock { try requiredPermit() }
        do {
            let returned = try await MiMoV26ModelFactory.loadContainer(session: session,
                reservation: held, prepared: prepared, retaining: work,
                isCancelled: { self.isCancellationRequested })
            // Retention is unconditional even after cancellation. It precedes
            // adoption, receipt await, metadata/capacity recheck and caller return.
            try lock.withLock {
                guard container == nil else { throw MiMoV26NativeTransactionError.foreignOwner }
                container = returned
            }
            try await work.acknowledgeContainerAdoption(returned)
            lock.withLock { adopted = true }
            let receipt = try await returned.perform { context in
                guard let model = context.model as? MiMoV26LoadedModel else {
                    throw MiMoV26NativeTransactionError.foreignOwner
                }
                return model.loadReceipt
            }
            try recheckSetup()
            try held.settleReturnedReceipt(receipt)
            try recheckSetup()
            switch MiMoV26WiredResidency.prepare(transactionID: id, lifecycle: lifecycle,
                request: request, receipt: receipt, budget: budget) {
            case .disabled:
                recordWiredResidencyProfile(event: "disabled")
            case .unsupported(let reason):
                recordWiredResidencyProfile(event: "unsupported", refusal: reason.rawValue)
            case .prepared(let owner):
                // This load operation already won the sole container adoption.
                // Retain BEFORE await, including a later-cancelled start result.
                lock.withLock { wiredResidency = owner }
                recordWiredResidencyProfile(event: "prepared", snapshot: owner.snapshot())
                let observation = await owner.start()
                recordWiredResidencyProfile(event: "start_returned", snapshot: observation)
                if observation.phase == .retainedFault {
                    registry?.retainFault(self, code: "wired_residency_start_failed")
                    throw MiMoV26NativeTransactionError.processFaulted
                }
                try recheckSetup()
            }
            return returned
        } catch { revoke(); throw error }
    }
    private func requiredPermit() throws -> MiMoV26PendingLoadReservation {
        guard let permit else { throw MiMoV26NativeTransactionError.invalidLifecycle }
        return permit
    }
    func withNativeConstruction<Result: Sendable>(
        _ body: @escaping @Sendable (MiMoV26LoadedModel, NativeConstructionScope) throws -> Result
    ) async throws -> Result {
        // A separate LIVE exclusive claim, not operations.isEmpty: the outer
        // performSetup must continue to own all its later awaits and vetoes.
        // Refuse before the SDK mutex/withPhase can advance the work epoch.
        let selected: (UUID, ModelContainer) = try registered(newWork: true) {
            try lock.withLock {
                guard !published, engine == nil else { throw MiMoV26NativeTransactionError.warmRebuildUnsupported }
                guard !cancelled else { throw CancellationError() }
                guard !draining, retired == nil, faultCode == nil, sealed == nil,
                      permit != nil, adopted, let container else {
                    throw MiMoV26NativeTransactionError.invalidLifecycle
                }
                guard nativeConstruction == nil else { throw MiMoV26NativeTransactionError.pendingWork }
                let id = UUID(); nativeConstruction = id; operations.insert(id)
                return (id, container)
            }
        }
        defer { endExclusiveOperation(selected.0) }
        do {
            let result = try await MiMoV26ModelFactory.withNativeConstruction(container: selected.1, retaining: work) { model, scope in
                // The protected SDK/container await may have crossed a stop.
                // No caller native body runs before this fresh host validation.
                try self.registered(newWork: true) {
                    try self.lock.withLock {
                        guard self.nativeConstruction == selected.0, self.operations.contains(selected.0),
                              !self.cancelled, !self.draining, self.retired == nil, self.faultCode == nil,
                              self.sealed == nil, !self.published, self.engine == nil,
                              self.adopted, self.container === selected.1 else {
                            throw MiMoV26NativeTransactionError.invalidLifecycle
                        }
                    }
                }
                return try body(model, scope)
            }
            try recheckSetup()
            return result
        } catch { revoke(); throw error }
    }

    /// No native work or actor read: bind the facade's raw candidate to this
    /// transaction's actual adopted object, including during metadata prep.
    func validateContainerIdentity(_ candidate: ModelContainer) throws {
        try registered(newWork: true) { try lock.withLock { try validateContainerLocked(candidate) } }
    }
    private func validateContainerLocked(_ candidate: ModelContainer) throws {
        guard adopted, container === candidate else { throw MiMoV26NativeTransactionError.foreignOwner }
        guard !cancelled, !draining, retired == nil, faultCode == nil, permit != nil else {
            throw MiMoV26NativeTransactionError.invalidLifecycle
        }
    }
    /// Root calls this BEFORE its owned-construction catch. A duplicate/warm
    /// refusal does not revoke an existing pipeline. The claim is one-shot for
    /// this transaction, independent of each live native-construction operation.
    func claimSlotAssembly(_ candidate: ModelContainer) throws {
        try registered(newWork: true) {
            try lock.withLock {
                try validateContainerLocked(candidate)
                guard !published else { throw MiMoV26NativeTransactionError.warmRebuildUnsupported }
                guard !slotAssemblyClaimed, engine == nil, bridge == nil, sealed == nil else {
                    throw MiMoV26NativeTransactionError.slotAssemblyAlreadyClaimed
                }
                guard nativeConstruction == nil else { throw MiMoV26NativeTransactionError.pendingWork }
                slotAssemblyClaimed = true
            }
        }
    }

    /// Capture before any later throw/await. These methods deliberately accept
    /// an already-cancelled in-flight creation so a late result is not orphaned.
    func registerAssistant(_ value: ProviderMTPAssistantHandle) throws {
        try registered(newWork: false) {
            try lock.withLock {
                guard !draining, retired == nil, !operations.isEmpty else { throw MiMoV26NativeTransactionError.invalidLifecycle }
                guard assistant == nil || assistant === value else { throw MiMoV26NativeTransactionError.foreignOwner }
                assistant = value
            }
        }
    }
    func registerNativeCompletePrefixResources(_ value: MiMoV26NativePrefixResources) throws {
        try registered(newWork: false) {
            try lock.withLock {
                guard !draining, retired == nil, !operations.isEmpty,
                      value.transactionID == id, value.sessionID == request.sessionID,
                      value.budget === budget,
                      nativePrefixResources == nil || nativePrefixResources === value else {
                    throw MiMoV26NativeTransactionError.foreignOwner
                }
                nativePrefixResources = value
            }
        }
    }

    /// Actor admission asks only about THIS installed engine/bridge/budget.
    /// The SDK ticket consumed the exact process owner passed by this factory;
    /// its Admission prices full KV + SWA + resolved bounded MTP/auxiliary state.
    /// An arbitrary EngineV2 marker or a foreign budget cannot skip bridge R.
    func ownsNativeCompletePrefixRequestCharge(engine expectedEngine: EngineV2,
        bridge expectedBridge: EngineV2Bridge, budget expectedBudget: GlobalKVCacheBudget) -> Bool {
        do {
            return try registered(newWork: true) {
                lock.withLock {
                    published && !cancelled && !draining && retired == nil && faultCode == nil
                        && budget === expectedBudget && engine === expectedEngine && bridge === expectedBridge
                        && (contract.map { nativePrefixResources?.matches(engine: expectedEngine, contract: $0) == true } == true)
                }
            }
        } catch { return false }
    }

    func registerEngine(_ value: EngineV2, executionContract: CBv2NativeExecutionContract) throws {
        try registered(newWork: false) {
            try lock.withLock {
                guard !draining, retired == nil, !operations.isEmpty else { throw MiMoV26NativeTransactionError.invalidLifecycle }
                // SDK issuance binds to THIS private construction work/epoch,
                // not merely to some real engine from another transaction.
                guard matchesConstruction(executionContract) else {
                    throw MiMoV26NativeTransactionError.foreignOwner
                }
                guard engine == nil || (engine === value && contract?.id == executionContract.id) else {
                    throw MiMoV26NativeTransactionError.foreignOwner
                }
                engine = value; contract = executionContract
                // Capture first; even a rejected late prefix proof owns a real
                // engine. Common's consumed ticket verifies this exact store,
                // process owner, loaded validator, bank and optional assistant.
                if executionContract.supportsNativeCompletePrefix {
                    guard let owner = nativePrefixResources else {
                        throw MiMoV26NativeTransactionError.unsupportedExecutionContract
                    }
                    try owner.bind(engine: value, contract: executionContract)
                }
                // Capture first; a refused proof must not discard the real engine.
                guard Self.supportsProfile(executionContract), matchesAudioContract(executionContract),
                      value.nativeShutdownExecutionContractID == executionContract.id else {
                    throw MiMoV26NativeTransactionError.unsupportedExecutionContract
                }
            }
        }
    }
    func registerBridge(_ value: EngineV2Bridge) throws {
        try registered(newWork: false) {
            try lock.withLock {
                guard !draining, retired == nil, !operations.isEmpty, engine != nil,
                      let contract, matchesConstruction(contract) else {
                    throw MiMoV26NativeTransactionError.invalidLifecycle
                }
                guard bridge == nil || bridge === value else { throw MiMoV26NativeTransactionError.foreignOwner }
                bridge = value
            }
        }
    }

    /// Called by the actor's weak-link attach seam. This validates the exact
    /// already-owned actor and trusted engine/work provenance without awaiting
    /// or reading actor-isolated engine fields under these locks.
    func validateRegisteredBridge(_ candidate: EngineV2Bridge) throws {
        try registered(newWork: true) {
            try lock.withLock {
                guard bridge === candidate, let engine, let contract,
                      !operations.isEmpty, adopted, container != nil, permit != nil,
                      !cancelled, !published, !draining, retired == nil,
                      faultCode == nil, sealed == nil,
                      matchesConstruction(contract),
                      engine.nativeShutdownExecutionContractID == contract.id else {
                    throw MiMoV26NativeTransactionError.foreignOwner
                }
            }
        }
    }

    /// Transfer the real factory result before it can be dropped by an outer
    /// setup veto. Accept cancellation during that owned transfer; retirement
    /// cannot start until the active operation unwinds. No facade/transaction
    /// may be the bundle's assistant owner, and the bridge link stays weak.
    func registerBundle(_ value: ProviderEngineBundle) throws {
        try registered(newWork: false) {
            try lock.withLock {
                guard !draining, retired == nil, !operations.isEmpty,
                      let bridge, bridge === value.bridge, let engine, let contract,
                      matchesConstruction(contract),
                      engine.nativeShutdownExecutionContractID == contract.id else {
                    throw MiMoV26NativeTransactionError.foreignOwner
                }
                guard bundle == nil || bundle === value else { throw MiMoV26NativeTransactionError.foreignOwner }
                bundle = value
            }
        }
    }

    private func matchesConstruction(_ contract: CBv2NativeExecutionContract) -> Bool {
        let snapshot = work.snapshot
        return Self.supportsProfile(contract)
            && contract.constructionOwnerID == snapshot.ownerID
            && contract.constructionEpoch == snapshot.epoch
            && !snapshot.isRetainedFault
    }
    private static func supportsProfile(_ contract: CBv2NativeExecutionContract) -> Bool {
        contract.profile == "mimo_text_contiguous_default_and_cpu_v1"
            || contract.supportsManagedDecodedMedia
            || (contract.supportsNativeCompletePrefix
                && contract.profile == "mimo_complete_text_prefix_contiguous_default_and_cpu_v1")
    }

    /// Existing published owner + actual model/engine operation. Never calls
    /// withNativeConstruction, advances an epoch or assembles a second target.
    func prepareDecodedMedia(_ input: MiMoV26MultimodalInput,
        policy: MiMoV26ServingLoad.DecodedMediaPolicy,
        expectedContainer: ModelContainer, expectedBridge: EngineV2Bridge,
        existingReservation: MiMoV26ManagedMediaReservation? = nil
    ) async throws -> (request: CBv2Request, engine: EngineV2) {
        let selected: (UUID, ModelContainer, EngineV2, CBv2NativeExecutionContract) = try registered(newWork: true) {
            try lock.withLock {
                guard published, !cancelled, !draining, retired == nil, faultCode == nil,
                      container === expectedContainer, bridge === expectedBridge,
                      let container, let engine, let contract, contract.supportsManagedDecodedMedia,
                      engine.nativeShutdownExecutionContractID == contract.id,
                      matchesConstruction(contract), matchesAudioContract(contract) else {
                    throw MiMoV26NativeTransactionError.foreignOwner
                }
                let id = UUID(); operations.insert(id)
                return (id, container, engine, contract)
            }
        }
        defer { endOperation(selected.0) }
        let cancellation = MediaCancellation()
        return try await withTaskCancellationHandler {
            var prepared: CBv2Request?
            do {
                try Task.checkCancellation()
                prepared = try await selected.1.perform { context in
                    try self.requireServingWorkAllowed()
                    guard let model = context.model as? MiMoV26LoadedModel else {
                        throw MiMoV26NativeTransactionError.foreignOwner
                    }
                    let audio: MiMoV26ManagedMediaReservation.AudioBinding?
                    if selected.3.supportsDecodedAudioMedia {
                        let held = try self.lock.withLock { () throws -> MiMoV26AudioSidecarReservation in
                            guard let reservation = self.audioReservation,
                                  self.matchesAudioContract(selected.3) else {
                                throw MiMoV26NativeTransactionError.foreignOwner
                            }
                            return reservation
                        }
                        let receipt = try model.validateInstalledAudioSidecar(expectedRequest: held.request)
                        guard receipt.codecGeneration == selected.3.audioSidecarGeneration,
                              receipt.sourceIdentity == selected.3.audioSidecarSourceIdentity else {
                            throw MiMoV26NativeTransactionError.foreignOwner
                        }
                        audio = .init(receipt: receipt, reservation: held)
                    } else { audio = nil }
                    let authorize: (MiMoV26MultimodalPlan, Int) throws -> any MiMoV26MediaWorkReservation = { plan, bytes in
                            try self.requireServingWorkAllowed()
                            if let existingReservation {
                                guard self.lock.withLock({ self.mediaReservations[existingReservation.id] === existingReservation }) else {
                                    throw MiMoV26NativeTransactionError.foreignOwner
                                }
                                try existingReservation.adoptNativePlan(plan,bytes:bytes,audioBinding:audio)
                                return existingReservation
                            }
                            let reservation = try MiMoV26ManagedMediaReservation(plan: plan, bytes: bytes,
                                maximumBytes: policy.maximumReservationBytes,
                                additionalSystemReserveBytes: policy.additionalSystemReserveBytes,
                                ledger: self.budget.processLedger,audioBinding:audio)
                            // Retain the real charged owner before returning it
                            // to the SDK or crossing any further veto.
                            self.lock.withLock { self.mediaReservations[reservation.id] = reservation }
                            return reservation
                    }
                    let retire: (any MiMoV26MediaWorkReservation) throws -> Void = { value in
                            guard let reservation = value as? MiMoV26ManagedMediaReservation else {
                                throw MiMoV26NativeTransactionError.foreignOwner
                            }
                            try reservation.retireAfterNativeCompletion()
                            self.removeSettledMediaReservation(reservation)
                    }
                    if audio != nil {
                        return try model.prepareManagedDecodedAudioMedia(input,engine:selected.2,
                            authorize:authorize,retire:retire,
                            isCancelled:{ cancellation.isCancelled || self.isCancellationRequested })
                    }
                    return try model.prepareManagedDecodedMedia(input,engine:selected.2,
                        authorize:authorize,retire:retire,
                        isCancelled:{ cancellation.isCancelled || self.isCancellationRequested })
                }
                try Task.checkCancellation()
                try requireServingWorkAllowed()
                return (prepared!, selected.2)
            } catch {
                if let media = prepared?.multimodal { selected.2.discardUnsubmittedNativeMedia(media) }
                if let fault = selected.2.nativeCompletionFault,
                   fault.engineID == selected.2.nativeShutdownEngineID, fault.generation == 1 {
                    self.registry?.retainFault(self, code: "engine_" + fault.reason.rawValue)
                } else if selected.3.supportsDecodedAudioMedia {
                    self.retainAudioOwnerFailureIfNeeded(error)
                }
                throw error
            }
        } onCancel: { cancellation.cancel() }
    }

    private func retainAudioOwnerFailureIfNeeded(_ error: Error) {
        if error is CancellationError || error as? MiMoV26MultimodalError == .reservationRejected { return }
        if let failure = error as? MiMoV26AudioSidecarError {
            if failure == .cancelled || failure == .insufficientReservation { return }
            if failure == .invalidatedOwner && isCancellationRequested { return }
            registry?.retainFault(self,code:"audio_owner_validation_failed")
        } else if let failure = error as? ProcessMemoryLedger.Refusal {
            if failure == .insufficientCapacity || failure == .stalePolicy { return }
            registry?.retainFault(self,code:"audio_ledger_integrity_failed")
        }
    }

    var managedMediaReservationCountForTesting: Int { lock.withLock { mediaReservations.count } }
    var managedMediaChargedBytesForTesting: UInt64 {
        lock.withLock { mediaReservations.values.reduce(0) { $0 + $1.chargedBytesForTesting } }
    }

    /// Called only by the native slot's protected construction path. Retains
    /// metadata weakly to avoid facade -> transaction -> facade ownership.
    func registerDecodedMediaFacade(_ load: MiMoV26ServingLoad,
        sampling: MiMoV26EncodedVisualDecoder.Sampling) throws {
        try registered(newWork:true) {
            try lock.withLock {
                guard !published, !cancelled, !draining, retired == nil, faultCode == nil,
                      nativeConstruction != nil, !operations.isEmpty,
                      load.transaction === self, load.request.sessionID == request.sessionID,
                      load.decodedMediaPolicy != nil,
                      decodedMediaFacade == nil || decodedMediaFacade === load else {
                    throw MiMoV26NativeTransactionError.foreignOwner
                }
                decodedMediaFacade = load; decodedVideoSampling = sampling
            }
        }
    }
    func decodedMediaBinding(expectedBridge: EngineV2Bridge) throws
        -> (load: MiMoV26ServingLoad, sampling: MiMoV26EncodedVisualDecoder.Sampling) {
        try registered(newWork:true) {
            try lock.withLock {
                guard published, !cancelled, !draining, retired == nil, faultCode == nil,
                      bridge === expectedBridge, let contract, contract.supportsManagedDecodedMedia,
                      matchesAudioContract(contract),
                      let load = decodedMediaFacade, load.transaction === self,
                      let sampling = decodedVideoSampling else {
                    throw MiMoV26NativeTransactionError.unsupportedExecutionContract
                }
                return (load,sampling)
            }
        }
    }
    func decodedAudioBinding(expectedBridge: EngineV2Bridge) throws
        -> (load: MiMoV26ServingLoad, receipt: MiMoV26AudioSidecarLoadReceipt) {
        try registered(newWork: true) {
            try lock.withLock {
                guard published, !cancelled, !draining, retired == nil, faultCode == nil,
                      bridge === expectedBridge, let contract, contract.supportsDecodedAudioMedia,
                      matchesAudioContract(contract), let receipt = audioReceipt,
                      let load = decodedMediaFacade, load.transaction === self,
                      load.decodedAudioPolicy != nil else {
                    throw MiMoV26NativeTransactionError.unsupportedExecutionContract
                }
                return (load,receipt)
            }
        }
    }
    func beginEncodedMediaReservation(initialBytes: UInt64, hostBytes: UInt64,
        policy: MiMoV26ServingLoad.DecodedMediaPolicy, lease: NativeLocalConsumerLease) throws
        -> MiMoV26ManagedMediaReservation {
        guard hostBytes > 0 else { throw MiMoV26MultimodalError.reservationRejected }
        try requireServingWorkAllowed()
        let reservation = try MiMoV26ManagedMediaReservation(initialBytes:initialBytes,hostBytes:hostBytes,
            maximumBytes:policy.maximumReservationBytes,
            additionalSystemReserveBytes:policy.additionalSystemReserveBytes,ledger:budget.processLedger)
        lock.withLock { mediaReservations[reservation.id] = reservation }
        do {
            try lease.installMediaHostCompletion(id:reservation.id) { [weak self, reservation] in
                do {
                    try reservation.completeHostOwnership()
                    self?.removeSettledMediaReservation(reservation)
                } catch {
                    // Actual owner/charge stay retained. Do not report memory
                    // credit or fabricate a native completion after refusal.
                    if let self { self.registry?.retainFault(self,code:"media_host_accounting_failed") }
                }
            }
        } catch {
            // No decoder or native work has started and no encoded owner was
            // installed. This is the exact cold-admission rollback only.
            try reservation.disposeUnstartedEncodedPromise()
            removeSettledMediaReservation(reservation)
            throw error
        }
        return reservation
    }
    private func removeSettledMediaReservation(_ reservation: MiMoV26ManagedMediaReservation) {
        guard reservation.isFullyRetired else { return }
        lock.withLock {
            if mediaReservations[reservation.id] === reservation {
                mediaReservations.removeValue(forKey:reservation.id)
            }
        }
    }

    func registerDecodedMediaConsumer(_ lease: NativeLocalConsumerLease,
        container candidate: ModelContainer, bridge candidateBridge: EngineV2Bridge) throws {
        try registered(newWork: true) {
            try lock.withLock {
                guard published, !cancelled, !draining, retired == nil, faultCode == nil,
                      container === candidate, bridge === candidateBridge,
                      let contract, contract.supportsManagedDecodedMedia,
                      matchesAudioContract(contract) else {
                    throw MiMoV26NativeTransactionError.foreignOwner
                }
                // Only prune completed HOST bookkeeping. This is never SDK
                // completion, array retirement, a charge reduction or refund.
                mediaConsumers = mediaConsumers.filter {
                    let phase = $0.value.snapshot().phase
                    return phase != .completed && phase != .abandoned
                }
                guard mediaConsumers[lease.id] == nil else {
                    throw NativeLocalConsumerOwnershipError.preparationAlreadyStarted
                }
                mediaConsumers[lease.id] = lease
            }
        }
    }

    func currentConstructionReceipt() throws -> NativeConstructionReceipt {
        let snapshot = work.snapshot
        guard case .completed(let receipt) = snapshot.disposition else {
            throw MiMoV26NativeTransactionError.pendingWork
        }
        try work.validate(receipt)
        return receipt
    }
    func sealConstructionForPublication() async throws -> NativeConstructionReceipt {
        try recheckSetup()
        let selected = try registered(newWork: true) {
            try lock.withLock {
                guard operations.isEmpty, adopted, container != nil, !draining,
                      sealed == nil, let engine, let bridge, bundle != nil, let contract,
                      matchesConstruction(contract), engine.nativeShutdownExecutionContractID == contract.id else {
                    throw MiMoV26NativeTransactionError.pendingWork
                }
                let receipt = try currentConstructionReceipt()
                draining = true // excludes new operations while the SDK seal awaits
                return (receipt, engine, bridge)
            }
        }
        defer { lock.withLock { draining = false } }
        guard let actual = await selected.2.ownedEngine as? EngineV2,
              actual === selected.1 else { throw MiMoV26NativeTransactionError.foreignOwner }
        let receipt = selected.0
        try await work.sealForPublication(receipt)
        try registered(newWork: true) {
            try lock.withLock {
                guard !cancelled, faultCode == nil else { throw MiMoV26NativeTransactionError.invalidLifecycle }
                sealed = receipt
            }
        }
        return receipt
    }

    /// Root's final slot/session insertion MUST occur inside this nonthrowing,
    /// nonsuspending callback. It must not reenter registry/transaction methods.
    /// Every throwable veto precedes permit retirement and this callback.
    func commitPublication<Result>(_ commit: () -> Result) throws -> Result {
        try registered(newWork: true) {
            try lock.withLock {
                guard !cancelled, !published, !draining, retired == nil, faultCode == nil,
                      operations.isEmpty, adopted, container != nil, engine != nil, bridge != nil, bundle != nil,
                      let sealed, let permit, let contract,
                      matchesConstruction(contract),
                      sealed.ownerID == contract.constructionOwnerID,
                      sealed.epoch == contract.constructionEpoch else {
                    throw MiMoV26NativeTransactionError.invalidLifecycle
                }
                try work.validate(sealed)
                guard permit.snapshot().lifecycle == .setup else { throw MiMoV26NativeTransactionError.invalidLifecycle }
                guard try permit.finishSetupAfterAccounting() else { throw MiMoV26NativeTransactionError.invalidLifecycle }
                published = true
                return commit()
            }
        }
    }

    /// No caller-supplied completion Boolean/receipt. Invoke the actual owned
    /// engine/bridge, validate its SDK-issued proof, then release this owner's
    /// resources and future charge. Root still observes allocator/OS headroom
    /// before clearing caches/regrowing; no physical reclamation is asserted.
    func retire() async -> MiMoV26NativeRetirement {
        if let retired = retirementReceipt { return await finishWiredResidencyRetirement(retired) }
        revoke()
        let mediaConsumersToClose = lock.withLock { Array(mediaConsumers.values) }
        for consumer in mediaConsumersToClose { consumer.closeAndCancel() }
        // Closing actual host IO is cancellation, NOT native completion/credit.
        // Fault exits retain the store, process owner and all native roots.
        lock.withLock { nativePrefixResources }?.close()
        guard let registry else { return .pending(.registryUnavailable) }
        if work.snapshot.isRetainedFault {
            registry.retainFault(self, code: "construction_completion_failed")
        }
        if let code = lock.withLock({ faultCode }) { return .retainedFault(code: code) }
        guard registry.taskCount(self) == 0 else { return .pending(.ownedTasks) }
        var selected: (EngineV2?, CBv2NativeExecutionContract?, EngineV2Bridge?, ModelContainer?, Bool)
        do {
            selected = try registered(newWork: false) {
                try lock.withLock {
                    guard !draining else { throw MiMoV26NativeRetirementControl.pending(.alreadyDraining) }
                    guard operations.isEmpty else { throw MiMoV26NativeRetirementControl.pending(.activeOperations) }
                    draining = true
                    return (engine, contract, bridge, container, adopted)
                }
            }
        } catch let MiMoV26NativeRetirementControl.pending(reason) { return .pending(reason) }
        catch { return .pending(.registryUnavailable) }
        defer { lock.withLock { draining = false } }
        let construction: NativeConstructionReceipt
        do {
            if case .idle = work.snapshot.disposition {
                construction = try await work.finishUnstartedConstruction()
            } else {
                construction = try currentConstructionReceipt()
            }
            if let container = selected.3, !selected.4 {
                try await work.acknowledgeContainerAdoption(container)
                lock.withLock { adopted = true }
            }
        } catch { return .pending(selected.3 != nil && !selected.4 ? .containerAdoption : .constructionActive) }

        var nativeReceipt = lock.withLock { completedEngineReceipt }
        if let engine = selected.0 {
            guard let contract = selected.1,
                  matchesConstruction(contract),
                  construction.ownerID == contract.constructionOwnerID,
                  construction.epoch == contract.constructionEpoch,
                  engine.nativeShutdownExecutionContractID == contract.id else {
                return .pending(.engineProofUnavailable)
            }
            let outcome: CBv2NativeShutdownOutcome
            do {
                if contract.supportsNativeCompletePrefix && !lock.withLock({ prefixAliasesDetached }) {
                    guard let actualContainer = selected.3 else {
                        return .pending(.identityMismatch)
                    }
                    do {
                        try await actualContainer.perform { context in
                            guard let model = context.model as? MiMoV26LoadedModel else {
                                throw MiMoV26NativeTransactionError.foreignOwner
                            }
                            try model.beginNativeCompletePrefixRetirement(executionContractID: contract.id)
                        }
                    } catch {
                        registry.retainFault(self, code: "prefix_owner_validation_failed")
                        return .retainedFault(code: "prefix_owner_validation_failed")
                    }
                }
                if let bridge = selected.2 {
                    outcome = try await bridge.shutdownNativeConstruction(
                        expectedEngine: engine, executionContractID: contract.id)
                } else {
                    outcome = await engine.shutdownReportingNativeCompletion()
                }
            } catch MiMoV26NativeBridgeShutdownError.pendingConsumers { return .pending(.hostConsumers) }
            catch MiMoV26NativeBridgeShutdownError.identityMismatch { return .pending(.identityMismatch) }
            catch let MiMoV26NativeBridgeShutdownError.failedCompletion(code) {
                let allowed = ["bridge_consumer_join_failed", "bridge_native_completion_failed", "bridge_lifecycle_fault"]
                let safe = allowed.contains(code) ? code : "invalid_bridge_fault_code"
                registry.retainFault(self, code: safe)
                return .retainedFault(code: safe)
            } catch {
                // No reflected error text and no invented successful SDK receipt.
                return .pending(.hostConsumers)
            }
            switch outcome {
            case .quiescent(let receipt):
                guard receipt.engineID == engine.nativeShutdownEngineID,
                      receipt.executionContractID == contract.id, receipt.generation == 1 else {
                    return .pending(.identityMismatch)
                }
                nativeReceipt = receipt
                lock.withLock { completedEngineReceipt = receipt }
            case .incomplete(let fault):
                guard fault.engineID == engine.nativeShutdownEngineID, fault.generation == 1 else {
                    return .pending(.identityMismatch)
                }
                switch fault.reason {
                case .notTracked, .unsupportedExecutionContract:
                    return .pending(.engineProofUnavailable)
                case .shutdownTimedOut, .stepWatchdog, .capturedFenceFailed, .nativeWorkFailed:
                    let code = "engine_" + fault.reason.rawValue
                    registry.retainFault(self, code: code)
                    return .retainedFault(code: code)
                @unknown default: return .pending(.engineProofUnavailable)
                }
            @unknown default: return .pending(.engineProofUnavailable)
            }
        } else if selected.2 != nil { return .pending(.identityMismatch) }

        // Real dependent host joins occur ONLY after the real SDK+bridge proof
        // above. Unknown/fault paths return earlier with all handles retained.
        for consumer in mediaConsumersToClose { await consumer.joinFromOutside() }
        if let code = lock.withLock({ faultCode }) { return .retainedFault(code: code) }
        guard lock.withLock({ mediaReservations.isEmpty }) else { return .pending(.permitSettlement) }
        do {
            try work.validate(construction)
            if let prefix = lock.withLock({ nativePrefixResources }) {
                // Real read/write + close joins, outside every native/TX lock.
                await prefix.closeAndWait()
                if selected.1?.supportsNativeCompletePrefix == true {
                    guard let receipt = nativeReceipt, let actualContainer = selected.3 else {
                        return .pending(.identityMismatch)
                    }
                    do { try prefix.acceptRetirement(receipt) }
                    catch {
                        registry.retainFault(self, code: "prefix_ledger_retirement_failed")
                        return .retainedFault(code: "prefix_ledger_retirement_failed")
                    }
                    if !lock.withLock({ prefixAliasesDetached }) {
                        try await actualContainer.perform { context in
                            guard let model = context.model as? MiMoV26LoadedModel else {
                                throw MiMoV26NativeTransactionError.foreignOwner
                            }
                            try model.releaseNativeCompletePrefixAfterNativeRetirement(receipt)
                        }
                        lock.withLock { prefixAliasesDetached = true }
                    }
                } else {
                    // Prefix preparation never issued/bound an engine: all
                    // native construction still had to finish above. Only
                    // its zero-charge, unbound host owner can retire here.
                    try prefix.retireUnusedOwner()
                }
            }
            let sidecar = lock.withLock { audioReservation }
            if let sidecar {
                if !lock.withLock({ audioAliasesDetached }) {
                    if let actualContainer = selected.3 {
                        if selected.1?.supportsDecodedAudioMedia == true, let receipt = nativeReceipt {
                            try await actualContainer.perform { context in
                                guard let model = context.model as? MiMoV26LoadedModel else {
                                    throw MiMoV26NativeTransactionError.foreignOwner
                                }
                                try model.releaseManagedAudioAfterNativeRetirement(receipt)
                            }
                        } else if selected.0 == nil {
                            // The protected load may have installed the codec
                            // before a later healthy setup veto. Only its exact
                            // completed installation epoch can detach it.
                            try await actualContainer.perform { context in
                                guard let model = context.model as? MiMoV26LoadedModel else {
                                    throw MiMoV26NativeTransactionError.foreignOwner
                                }
                                try model.releaseInstalledAudioAfterConstructionCompletion(construction)
                            }
                        } else { return .pending(.identityMismatch) }
                    } else if lock.withLock({ audioReceipt != nil }) {
                        return .pending(.identityMismatch)
                    }
                    // No installed owner exists if there was no container and
                    // setup has genuinely drained. This is not a count proof.
                    lock.withLock { audioAliasesDetached = true }
                }
                if let code = lock.withLock({ faultCode }) { return .retainedFault(code: code) }
                // Codec/processor/prepared aliases are detached after actual
                // native+bridge+consumer proof. No TX/registry/outcome lock.
                do { try sidecar.retireAfterNativeAliasesReleased() }
                catch {
                    registry.retainFault(self,code:"audio_ledger_settlement_failed")
                    return .retainedFault(code:"audio_ledger_settlement_failed")
                }
            }
            // Existing success ordering: engine/bridge completion, assistant,
            // external resources, then raw container/engine aliases, then C.
            let heldBundle = lock.withLock { bundle }
            heldBundle?.releaseAssistant()
            let heldAssistant = lock.withLock { assistant }
            heldAssistant?.release()
            await ModelContainerLoading.releaseExternalResources(in: selected.3)
            // Drop this cleanup operation's temporary native aliases as well.
            // Remaining caller aliases still belong to allocator A, never M.
            selected = (nil, nil, nil, nil, false)
            try registered(newWork: false) {
                try lock.withLock {
                    guard faultCode == nil, operations.isEmpty, mediaReservations.isEmpty else {
                        throw MiMoV26NativeTransactionError.pendingWork
                    }
                    try work.validate(construction)
                    bundle = nil; assistant = nil; bridge = nil; engine = nil; contract = nil; container = nil
                    mediaConsumers.removeAll()
                    decodedMediaFacade = nil; decodedVideoSampling = nil
                    adopted = false; sealed = nil
                    _ = try permit?.finishFailureAfterNativeDrain()
                    retired = .init(transactionID: id, sessionID: request.sessionID,
                                    lifecycle: lifecycle, construction: construction, engine: nativeReceipt,
                                    audioSessionID: audioRequest?.sessionID)
                    audioReservation = nil; audioReceipt = nil; audioRequest = nil
                    nativePrefixResources = nil
                }
            }
        } catch { return .pending(.permitSettlement) }
        guard let receipt = retirementReceipt else { return .pending(.permitSettlement) }
        return await finishWiredResidencyRetirement(receipt)
    }

    /// The existing FINAL receipt was issued after real native/bridge/consumer
    /// retirement, alias detach and permit settlement. Do not move that receipt
    /// earlier or treat the ticket's manager result as another memory refund.
    private func finishWiredResidencyRetirement(
        _ receipt: MiMoV26NativeRetirementReceipt
    ) async -> MiMoV26NativeRetirement {
        if let owner = lock.withLock({ wiredResidency }) {
            let outcome = await owner.end(after: receipt)
            recordWiredResidencyProfile(event: "end_returned", snapshot: owner.snapshot())
            switch outcome {
            case .ended:
                break // logical manager bookkeeping only; restoration unverified
            case .pendingStart, .pendingEnd:
                return .pending(.wiredResidencySettlement)
            case .foreignReceipt:
                return .pending(.identityMismatch)
            case .retainedFault:
                registry?.retainFault(self, code: "wired_residency_retirement_failed")
                return .retainedFault(code: "wired_residency_retirement_failed")
            }
        }
        registry?.removeRetired(self)
        return .retired(receipt)
    }

    /// Explicit profiling only. Scalar owner/policy observations contain no
    /// request content, paths or credentials and are NOT backend coverage proof.
    private func recordWiredResidencyProfile(event: String, refusal: String? = nil,
        snapshot: MiMoV26WiredResidency.Snapshot? = nil) {
        guard ProcessInfo.processInfo.environment["CBV2_STEP_PROFILE"] == "1" else { return }
        var fields: [String: Any] = [
            "event": event, "transaction_id": id.uuidString,
            "session_id": request.sessionID.uuidString,
            "requested": MiMoV26WiredResidency.isEnabled(),
            "backend_coverage_verified": false, "backend_restoration_verified": false,
        ]
        if let refusal { fields["refusal"] = refusal }
        if let snapshot {
            fields["phase"] = snapshot.phase.rawValue
            fields["resident_payload_bytes"] = snapshot.residentPayloadBytes
            fields["own_safe_ceiling_bytes"] = snapshot.ownSafeCeilingBytes
            fields["cancelled_when_start_returned"] = snapshot.cancelledWhenStartReturned
            fields["policy_only_test"] = snapshot.policyOnlyTest
            if let value = snapshot.managerStartValue { fields["manager_start_value"] = value }
            if let value = snapshot.managerEndValue { fields["manager_end_value"] = value }
            if let value = snapshot.capturedDeviceType { fields["captured_device_type"] = String(describing: value) }
            if let value = snapshot.capturedDeviceDescription { fields["captured_device"] = value }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        print("MIMO_WIRED_RESIDENCY \(text)")
    }

    func snapshot() -> Snapshot {
        let sdk = work.snapshot
        return lock.withLock {
            let phase: Phase = faultCode != nil ? .retainedFault : retired != nil ? .retired :
                draining ? .draining : cancelled ? .cancelling : published ? .published :
                sealed != nil ? .ready : container != nil ? .building : permit != nil ? .preparing : .registered
            return .init(id: id, sessionID: request.sessionID, lifecycleGeneration: lifecycle.generation,
                phase: phase, activeOperations: operations.count, hasContainer: container != nil,
                hasAssistant: assistant != nil, hasEngine: engine != nil, hasBridge: bridge != nil, hasBundle: bundle != nil,
                constructionEpoch: sdk.epoch, constructionPhase: sdk.phase,
                constructionFailed: sdk.isRetainedFault, faultCode: faultCode, permit: permit?.snapshot(),
                audioSessionID: audioRequest?.sessionID,
                audioChargedBytes: audioReservation?.chargedBytesForTesting ?? 0,
                hasInstalledAudioReceipt: audioReceipt != nil, audioAliasesDetached: audioAliasesDetached)
        }
    }
}
private enum MiMoV26NativeRetirementControl: Error {
    case pending(MiMoV26NativeRetirementPending)
}
