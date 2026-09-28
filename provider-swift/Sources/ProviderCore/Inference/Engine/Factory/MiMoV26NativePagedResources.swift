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

    init(transactionID: UUID, sessionID: UUID, budget: GlobalKVCacheBudget) {
        self.transactionID = transactionID; self.sessionID = sessionID; self.budget = budget
        processOwner = budget.makeEngineMemoryOwner()
    }
    func bind(engine: EngineV2, contract: CBv2NativeExecutionContract) throws {
        try lock.withLock {
            guard engineID == nil, contractID == nil, !retired,
                  contract.supportsNativePagedTarget,
                  engine.nativeShutdownExecutionContractID == contract.id,
                  engine.nativeCompletionFault == nil, engine.pagedAttentionWorkInactiveReason == nil,
                  engine.usesProcessMemoryOwner(processOwner) else { throw Failure.foreignOwner }
            engineID = engine.nativeShutdownEngineID; contractID = contract.id
        }
    }
    func matches(engine: EngineV2, contract: CBv2NativeExecutionContract) -> Bool {
        lock.withLock {
            !retired && contract.supportsNativePagedTarget
                && engineID == engine.nativeShutdownEngineID && contractID == contract.id
                && engine.usesProcessMemoryOwner(processOwner)
        }
    }
    func retireUnusedOwner() throws {
        try lock.withLock {
            guard engineID == nil, contractID == nil else { throw Failure.alreadyBound }
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
            retired = true // verifies actual Common settlement, never refunds here
        }
    }
}
