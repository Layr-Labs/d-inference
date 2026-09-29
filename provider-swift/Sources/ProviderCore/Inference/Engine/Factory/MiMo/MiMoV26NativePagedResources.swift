// Copyright © 2026 Eigen Labs.
import Foundation
import MLXLMCommon

/// Retains the EXISTING global process owner, not a new budget or registry.
/// TX captures it before protected assembly/await. No deinit refund or fabricated
/// retirement; Common closes this owner only after its actual pool/work drains.
final class MiMoV26NativePagedResources: @unchecked Sendable {
    enum Failure: Error { case foreignOwner, alreadyBound, incompleteRetirement }
    let transactionID, sessionID: UUID
    let budget: GlobalKVCacheBudget
    let processOwner: EngineProcessMemoryOwner
    private let lock = NSLock()
    private var engineID, contractID: UUID?
    private var retired = false
    private var prefixIdentity: CBv2CompleteCheckpointIdentity?
    private var prefixLayout: String?
    private var heldStore: SSDHybridCheckpointStore?
    private var closeRequested = false
    private var closeJoined = false

    init(transactionID: UUID, sessionID: UUID, budget: GlobalKVCacheBudget) {
        self.transactionID = transactionID; self.sessionID = sessionID; self.budget = budget
        processOwner = budget.makeEngineMemoryOwner()
    }
    var store: SSDHybridCheckpointStore? { lock.withLock { heldStore } }
    func preparePrefix(identity: CBv2CompleteCheckpointIdentity, backendLayout: String) throws {
        try lock.withLock {
            guard engineID == nil, contractID == nil, !retired, prefixIdentity == nil, heldStore == nil,
                  !closeRequested, !closeJoined else { throw Failure.alreadyBound }
            prefixIdentity = identity; prefixLayout = backendLayout
        }
    }
    /// Capture the real late returned store BEFORE a setup cancellation/source
    /// veto. This owner already belongs to the transaction's active operation.
    func installPrefix(_ value: SSDHybridCheckpointStore) throws {
        let close = try lock.withLock {
            guard heldStore == nil, engineID == nil, !retired, !closeJoined,
                  value.kvBudget === budget, value.identity == prefixIdentity,
                  value.config.backendLayout == prefixLayout else { throw Failure.foreignOwner }
            heldStore = value
            return closeRequested
        }
        if close { value.close() }
    }
    func close() {
        let actual = lock.withLock { closeRequested = true; return heldStore }
        actual?.close()
    }
    func closeAndWait() async {
        close()
        let actual = store
        await actual?.closeAndWait()
        lock.withLock { closeJoined = true }
    }
    func bind(engine: EngineV2, contract: CBv2NativeExecutionContract) throws {
        try lock.withLock {
            guard engineID == nil, contractID == nil, !retired,
                  contract.supportsNativePagedTarget,
                  engine.nativeShutdownExecutionContractID == contract.id,
                  engine.usesProcessMemoryOwner(processOwner) else { throw Failure.foreignOwner }
            guard contract.supportsNativeCompletePrefix == (heldStore != nil) else { throw Failure.foreignOwner }
            if let heldStore {
                guard engine.completePrefixCache === heldStore,
                      heldStore.identity == prefixIdentity,
                      heldStore.config.backendLayout == prefixLayout else { throw Failure.foreignOwner }
            }
            if contract.supportsNativePagedSerialMTP {
                guard contract.mtpVerificationMode == .serialTarget,
                      engine.mtpInactiveReason == nil,
                      engine.mtpMetricsSnapshot()?.verificationMode == .serialTarget,
                      case .bounded? = engine.resolvedMTPAdmission else { throw Failure.foreignOwner }
            } else {
                guard engine.mtpMetricsSnapshot() == nil else { throw Failure.foreignOwner }
            }
            // TX already captured this genuine late construction result.
            // Authenticate the immutable tuple first, then keep its exact
            // retirement IDs even if host cancellation closed the store while
            // the synchronous SDK body ran outside the TX lock. These IDs
            // permit receipt validation, NEVER permission to serve.
            engineID = engine.nativeShutdownEngineID; contractID = contract.id
            // A failed cache factory closes/joins an EMPTY prefix attempt and
            // intentionally reuses this same owner for uncached paging.
            // Once a real store was captured, closing still forbids serving.
            guard heldStore == nil || (!closeRequested && !closeJoined) else { throw Failure.foreignOwner }
            guard engine.nativeCompletionFault == nil, engine.pagedAttentionWorkInactiveReason == nil else {
                throw Failure.foreignOwner
            }
        }
    }
    func matches(engine: EngineV2, contract: CBv2NativeExecutionContract) -> Bool {
        lock.withLock {
            !retired && (heldStore == nil || (!closeRequested && !closeJoined))
                && contract.supportsNativePagedTarget
                && engineID == engine.nativeShutdownEngineID && contractID == contract.id
                && engine.usesProcessMemoryOwner(processOwner)
                && contract.supportsNativeCompletePrefix == (heldStore != nil)
                && (heldStore == nil || engine.completePrefixCache === heldStore)
        }
    }
    func retireUnusedOwner() throws {
        try lock.withLock {
            guard engineID == nil, contractID == nil, heldStore == nil || closeJoined else { throw Failure.alreadyBound }
            if retired { return }
            if let state = processOwner.snapshot() {
                guard state.chargedBytes == 0, state.materializedBytes == 0 else {
                    throw Failure.incompleteRetirement
                }
                processOwner.retire()
            }
            guard processOwner.snapshot() == nil else { throw Failure.incompleteRetirement }
            retired = true
        }
    }
    func acceptRetirement(_ receipt: CBv2NativeShutdownReceipt) throws {
        try lock.withLock {
            guard engineID == receipt.engineID, contractID == receipt.executionContractID,
                  receipt.generation == 1, processOwner.snapshot() == nil else {
                throw Failure.incompleteRetirement
            }
            guard heldStore == nil || closeJoined else { throw Failure.incompleteRetirement }
            retired = true // verifies actual Common settlement, never refunds here
        }
    }
}
