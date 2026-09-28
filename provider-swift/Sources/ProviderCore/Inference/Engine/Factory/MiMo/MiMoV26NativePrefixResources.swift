// Copyright © 2026 Eigen Labs.
import Foundation
import MLXLMCommon

/// Host-side ownership of the existing encrypted store and existing process
/// ledger owner. No model/binding/array, new ledger, receipt issuer or deinit
/// refund lives here. TX retains this before its first host await.
final class MiMoV26NativePrefixResources: @unchecked Sendable {
    enum Failure: Error { case foreignOwner, alreadyBound, incompleteRetirement }
    struct Snapshot: Sendable {
        let hasStore, bound, closeJoined, ownerRetired: Bool
        let chargedBytes, materializedBytes: UInt64
    }
    let transactionID, sessionID: UUID
    let budget: GlobalKVCacheBudget
    let processOwner: EngineProcessMemoryOwner
    let identity: CBv2CompleteCheckpointIdentity
    let backendLayout: String
    private let lock = NSLock()
    private var heldStore: SSDHybridCheckpointStore?
    private var engineID: UUID?
    private var contractID: UUID?
    private var closeJoined = false
    private var ownerRetired = false

    init(transactionID: UUID, sessionID: UUID, budget: GlobalKVCacheBudget,
         identity: CBv2CompleteCheckpointIdentity, backendLayout: String) {
        self.transactionID = transactionID; self.sessionID = sessionID; self.budget = budget
        self.identity = identity; self.backendLayout = backendLayout
        // The existing usage-reader preparation occurs outside registry/TX locks.
        processOwner = budget.makeEngineMemoryOwner()
    }
    var store: SSDHybridCheckpointStore? { lock.withLock { heldStore } }

    /// Returned late stores are captured before cancellation/source rechecks.
    /// The same helper is already in the TX's active preparation operation.
    func install(_ value: SSDHybridCheckpointStore) throws {
        try lock.withLock {
            guard heldStore == nil, engineID == nil, !closeJoined, !ownerRetired,
                  value.kvBudget === budget, value.identity == identity,
                  value.config.backendLayout == backendLayout else { throw Failure.foreignOwner }
            heldStore = value
        }
    }
    func bind(engine: EngineV2, contract: CBv2NativeExecutionContract) throws {
        try lock.withLock {
            guard engineID == nil, contractID == nil, !closeJoined, !ownerRetired,
                  let heldStore, contract.supportsNativeCompletePrefix,
engine.completePrefixCache === heldStore, engine.usesProcessMemoryOwner(processOwner),
                  engine.nativeShutdownExecutionContractID == contract.id else { throw Failure.foreignOwner }
            engineID = engine.nativeShutdownEngineID; contractID = contract.id
        }
    }
    func matches(engine: EngineV2, contract: CBv2NativeExecutionContract) -> Bool {
        lock.withLock {
            !ownerRetired && engineID == engine.nativeShutdownEngineID && contractID == contract.id
&& contract.supportsNativeCompletePrefix && engine.usesProcessMemoryOwner(processOwner)
                && heldStore != nil && engine.completePrefixCache === heldStore
        }
    }
    func close() { store?.close() } // actual synchronous cancellation, outside this lock

    func closeAndWait() async {
        let actual = store
        await actual?.closeAndWait() // actual read/write queues; never inferred from counters
        lock.withLock { closeJoined = true }
    }

    /// Only an UNBOUND, genuinely drained host preparation may retire its
    /// unused zero-charge owner. No native receipt is invented by this path.
    func retireUnusedOwner() throws {
        try lock.withLock {
            guard engineID == nil, contractID == nil, closeJoined else { throw Failure.alreadyBound }
            if ownerRetired { return }
            if let state = processOwner.snapshot() {
                guard state.chargedBytes == 0, state.materializedBytes == 0 else {
                    throw Failure.incompleteRetirement
                }
                processOwner.retire()
            }
            guard processOwner.snapshot() == nil else { throw Failure.incompleteRetirement }
            ownerRetired = true
        }
    }

    /// Common's authentic native shutdown closes Admission's owner after all
    /// arrays/loans retire. Verify that fact; do NOT withdraw or refund it here.
    func acceptRetirement(_ receipt: CBv2NativeShutdownReceipt) throws {
        try lock.withLock {
            guard engineID == receipt.engineID, contractID == receipt.executionContractID,
                  receipt.generation == 1, closeJoined, processOwner.snapshot() == nil else {
                throw Failure.incompleteRetirement
            }
            ownerRetired = true
        }
    }
    func snapshot() -> Snapshot {
        lock.withLock {
            let state = processOwner.snapshot()
            return .init(hasStore: heldStore != nil, bound: engineID != nil,
                closeJoined: closeJoined, ownerRetired: ownerRetired,
                chargedBytes: state?.chargedBytes ?? 0, materializedBytes: state?.materializedBytes ?? 0)
        }
    }
}
