import Foundation
import MLXLMCommon

extension EngineV2Bridge {
    struct NativeRetirementTaskSnapshot: Sendable {
        let sdkQuiescence: CBv2NativeShutdownReceipt?
        let tasks: [Task<Void, Never>]
        /// Change detection only: closure/proof state, pending/active maps and
        /// actual retained-task counts. Neither zeros nor equality prove drain.
        let progress: [Int]
    }

    /// Read actual handles for an external owner. Tasks which await native
    /// retirement must not be joined before sdkQuiescence matches that owner's
    /// exact engine/contract. Snapshotting or joining these handles is NOT final
    /// host completion/refund authority: the transaction/bridge revalidate after
    /// every join, including any task registered after this snapshot.
    func nativeRetirementTaskSnapshot() -> NativeRetirementTaskSnapshot {
        var tasks = nativeShutdownTasks
        tasks.append(contentsOf: pumpTasks.values)
        tasks.append(contentsOf: nativeTransferredRetirementTasks.values)
        if let prefixCacheStatsTask { tasks.append(prefixCacheStatsTask) }
        if let slotPostureTask { tasks.append(slotPostureTask) }
        return .init(sdkQuiescence: nativeSDKQuiescentReceipt, tasks: tasks,
            progress: [nativeShutdownClosed ? 1 : 0, nativeShutdownInProgress ? 1 : 0,
                nativeSDKQuiescentReceipt == nil ? 0 : 1, nativeShutdownResult == nil ? 0 : 1,
                pendingSubmissionIDs.count, pendingEngineIDs.count, active.count, idMap.count,
                pumpTasks.count, nativeTransferredRetirementTasks.count, nativeShutdownTasks.count])
    }

    /// First post-construction actor handoff. The transaction has already
    /// retained this exact bridge/engine/contract before any awaited configure.
    func attachNativeTransaction(_ transaction: MiMoV26NativeLoadTransaction) throws {
        guard tracksNativeShutdown, !nativeShutdownClosed,
            nativeTransactionID == nil || nativeTransactionID == transaction.id,
            nativeTransaction == nil || nativeTransaction === transaction else {
            throw MiMoV26NativeTransactionError.foreignOwner
        }
        try transaction.validateRegisteredBridge(self)
        nativeTransactionID = transaction.id
        nativeTransaction = transaction
    }

    /// Request admission only; not native completion or reclamation proof.
    /// The process fault fence applies to native-managed bridges. Other
    /// resident bridges still pass their ordinary engine and admission gates.
    /// A managed bridge cannot fall back to legacy admission after losing its
    /// weak owner or before actual lifecycle-gated publication.
    func canSubmitWithNativeOwner() -> Bool {
        guard !nativeShutdownClosed else { return false }
        do {
            if tracksNativeShutdown || nativeTransactionID != nil || nativeShutdownIdentity != nil {
                try MiMoV26NativeLoadRegistry.shared.requireNewNativeWorkAllowed()
                guard let transaction = nativeTransaction,
                    nativeTransactionID == transaction.id else { return false }
                try transaction.requireServingWorkAllowed()
            }
            return true
        } catch {
            return false
        }
    }

    /// Actual tracked engine plus host-consumer completion. This is not a
    /// physical-free or shared-ledger retirement receipt. The host transaction
    /// retains the real model/permit through this await and consumes the result.
    /// Initial SDK profile is the one-shot generation-1 native MiMo contract.
    func shutdownNativeConstruction(
        expectedEngine: EngineV2, executionContractID: UUID
    ) async throws -> CBv2NativeShutdownOutcome {
        let identity = NativeShutdownIdentity(
            engineID: expectedEngine.nativeShutdownEngineID, contractID: executionContractID)
        guard expectedEngine.nativeShutdownExecutionContractID == executionContractID,
            nativeShutdownIdentity == nil || nativeShutdownIdentity == identity else {
            throw MiMoV26NativeBridgeShutdownError.identityMismatch
        }
        if let result = nativeShutdownResult { return result }
        guard (ownedEngine as? EngineV2) === expectedEngine else {
            throw MiMoV26NativeBridgeShutdownError.identityMismatch
        }
        guard !nativeShutdownInProgress else {
            throw MiMoV26NativeBridgeShutdownError.pendingConsumers
        }
        if !nativeShutdownClosed {
            if let task = cancelMimoCalibration() { nativeShutdownTasks.append(task) }
            nativeShutdownActivity = serviceBudget?.beginUnboundedActivity()
            nativeShutdownIdentity = identity
            nativeShutdownClosed = true
            nativeShutdownTasks.append(contentsOf: pumpTasks.values)
            nativeShutdownTasks.append(contentsOf: nativeTransferredRetirementTasks.values)
            if let task = prefixCacheStatsTask { nativeShutdownTasks.append(task); task.cancel() }
            slotPostureClosed = true
            if let task = slotPostureTask { nativeShutdownTasks.append(task); task.cancel() }
            prefixCacheTelemetry.close()
            // Keep pumps alive to receive genuine native terminal/retirement.
            // Cancelling a pump itself is not a GPU completion acknowledgement.
            for id in Set(idMap.keys).union(pendingSubmissionIDs) { cancel(requestId: id) }
        }
        nativeShutdownInProgress = true
        defer { nativeShutdownInProgress = false }

        let outcome = await expectedEngine.shutdownReportingNativeCompletion()
        guard nativeShutdownIdentity == identity,
            (ownedEngine as? EngineV2) === expectedEngine else {
            throw MiMoV26NativeBridgeShutdownError.identityMismatch
        }
        switch outcome {
        case .incomplete(let fault):
            guard fault.engineID == identity.engineID, fault.generation == 1 else {
                throw MiMoV26NativeBridgeShutdownError.identityMismatch
            }
            // No task cancellation, owner release, refund, regrow or recovery.
            nativeShutdownResult = outcome
            return outcome
        case .quiescent(let receipt):
            guard receipt.engineID == identity.engineID, receipt.generation == 1,
                receipt.executionContractID == identity.contractID else {
                throw MiMoV26NativeBridgeShutdownError.identityMismatch
            }
            nativeSDKQuiescentReceipt = receipt
        }

        // A pre-submit caller can still be unwinding a suspended host operation.
        // Return explicit pending instead of fabricating host completion or
        // awaiting an unowned caller task. The registered owner retries after
        // that operation's actual completion, retaining every resource meantime.
        guard nativeHostConsumersHaveFinished else {
            throw MiMoV26NativeBridgeShutdownError.pendingConsumers
        }
        for task in nativeShutdownTasks { await task.value }
        guard nativeHostConsumersHaveFinished,
            nativeShutdownIdentity == identity,
            (ownedEngine as? EngineV2) === expectedEngine else {
            throw MiMoV26NativeBridgeShutdownError.pendingConsumers
        }
        // Current tracked profile has no prefix stores. Keep explicit joins here
        // for host objects, without treating them as SDK capability qualification.
        prefixCacheEvidenceSequencer?.shutdown()
        residentPrefixCacheEvidenceSequencer?.shutdown()
        residentPrefixCacheEvidence?.close()
        await ssdPrefixCache?.closeAndWait()
        await ssdHybridCheckpointStore?.closeAndWait()
        guard nativeHostConsumersHaveFinished else {
            throw MiMoV26NativeBridgeShutdownError.pendingConsumers
        }
        prefixCacheStatsTask = nil
        slotPostureTask = nil
        nativeShutdownTasks.removeAll()
        ownedEngine = nil
        nativeShutdownActivity?.finish()
        nativeShutdownActivity = nil
        deadlinePostureMonitoring?.finish()
        deadlinePostureMonitoring = nil
        nativeShutdownResult = outcome
        return outcome
    }

    private var nativeHostConsumersHaveFinished: Bool {
        pendingSubmissionIDs.isEmpty && pendingEngineIDs.isEmpty && active.isEmpty
            && idMap.isEmpty && pumpTasks.isEmpty && nativeTransferredRetirementTasks.isEmpty
    }
}
