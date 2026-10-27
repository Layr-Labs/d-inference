import MLX
import MLXLMCommon

/// Serialized state/evaluation core reusable by both ordinary and layer-stage
/// sessions. This owns no model, token schedule, output policy or returned arrays.
/// Callers must run native work inside MLX.withError and supply its check closure.
final class CBv2OwnedRequestState {
    let geometry: CBv2RequestGeometry
    let backend: CBv2ContiguousKVBackend
    let bank: CBv2LayerCacheBank
    let recurrent: CBv2RecurrentRequestState
    private(set) var rows: [CBv2SequenceKV?]
    private var evaluation: CBv2RecurrentStateEvaluation?
    private var verification: CBv2TargetVerification?
    private var evaluationWasStaged = false
    private(set) var committedTokens = 0
    private(set) var isClosed = false
    private(set) var isFailed = false
    let maximumTokens: Int

    init(geometry: CBv2RequestGeometry, promptCount: Int, outputCount: Int) throws {
        guard (1...32_768).contains(promptCount), (1...4096).contains(outputCount),
            promptCount <= 32_768 - outputCount,
            geometry.attentionLayout.map({ $0.maximumTokens == promptCount + outputCount }) ?? true else { throw ProbeError("CBv2 owned state exceeds the bounded request context") }
        let backend = CBv2ContiguousKVBackend(config: .init(
            bytesCapacity: geometry.kvCapacityBytes, kvDType: geometry.kvDType))
        let rows = try backend.makeSequenceState(layerKinds: geometry.kinds,
            promptLength: promptCount, maxLength: promptCount + outputCount)
        let recurrent: CBv2RecurrentRequestState
        do { recurrent = try CBv2RecurrentRequestState(spec: geometry.recurrent) }
        catch { backend.release(rows); throw error }
        guard rows.count == geometry.kinds.count,
            rows.allSatisfy({ $0?.absoluteOffset == 0 && $0?.retainedCount == 0 }),
            geometry.caches.allSatisfy({ $0.rows.isEmpty }),
            recurrent.confirmedStateSnapshot() == nil, recurrent.materializedByteCount == 0,
            !recurrent.isReleased else {
            backend.release(rows); try? recurrent.release()
            throw ProbeError("CBv2 state did not start with exclusive fresh ownership")
        }
        self.geometry = geometry; self.backend = backend
        self.bank = CBv2LayerCacheBank(caches: geometry.caches)
        self.recurrent = recurrent; self.rows = rows
        self.maximumTokens = promptCount + outputCount
    }

    func requireOpen() throws {
        guard !isClosed, !isFailed, evaluation == nil, verification == nil else {
            throw ProbeError("CBv2 state is retired, failed or has unfinished work")
        }
    }

    func run(tokenCount: Int, observer: CBv2OwnerPhaseObserver? = nil, check: () throws -> Void,
             additionalEvaluationTargets: (() -> [MLXArray])? = nil,
             forward: ([any CBv2AttendingLayerCache], CBv2RecurrentStateEvaluation) throws -> MLXArray,
             validateOutput: (MLXArray) throws -> Void) throws -> MLXArray {
        do {
            try requireOpen()
            guard tokenCount > 0, tokenCount <= maximumTokens - committedTokens,
                geometry.attentionLayout.map({ tokenCount <= $0.maximumChunkTokens }) ?? true else {
                throw ProbeError("CBv2 state advance exceeds the admitted capacity")
            }
            let caches = bank.layerCaches(rowStates: [rows])
            evaluation = try recurrent.bind(); evaluationWasStaged = false
            if let observer {
                try CBv2OwnerPhaseObservation(phase: .graphConstructionBegin, tokenCount: tokenCount, committedTokens: committedTokens)
                    .deliver(to: observer, check: check)
            }
            let output = try forward(caches, evaluation!)
            if let observer {
                try CBv2OwnerPhaseObservation(phase: .graphConstructionEnd, tokenCount: tokenCount, committedTokens: committedTokens)
                    .deliver(to: observer, check: check)
            }
            if let observer {
                try CBv2OwnerPhaseObservation(phase: .rootStagingBegin, tokenCount: tokenCount, committedTokens: committedTokens)
                    .deliver(to: observer, check: check)
            }
            let recurrentRoots = try evaluation!.evaluate(); evaluationWasStaged = true
            let cacheRoots = caches.flatMap { ($0 as! any KVCache).innerState() }
            if let observer {
                try CBv2OwnerPhaseObservation(phase: .rootStagingEnd, tokenCount: tokenCount, committedTokens: committedTokens)
                    .deliver(to: observer, check: check)
            }
            if let observer {
                try CBv2OwnerPhaseObservation(phase: .evaluationBegin, tokenCount: tokenCount, committedTokens: committedTokens)
                    .deliver(to: observer, check: check)
            }
            if let additionalEvaluationTargets {
                eval([output] + recurrentRoots + cacheRoots + additionalEvaluationTargets())
            } else {
                eval([output] + recurrentRoots + cacheRoots)
            }
            try check()
            if let observer {
                try CBv2OwnerPhaseObservation(phase: .evaluationEnd, tokenCount: tokenCount, committedTokens: committedTokens)
                    .deliver(to: observer, check: check)
            }
            if let observer {
                try CBv2OwnerPhaseObservation(phase: .validationCommitBegin, tokenCount: tokenCount, committedTokens: committedTokens)
                    .deliver(to: observer, check: check)
            }
            try validateOutput(output)
            try validateState(after: committedTokens + tokenCount)
            try check()
            try evaluation!.commit()
            evaluation = nil; evaluationWasStaged = false
            committedTokens += tokenCount
            guard Set(recurrent.confirmedStateSnapshot()?.keys.map { $0 } ?? [])
                == Set(geometry.recurrent.modelLayerIndices) else {
                throw ProbeError("CBv2 recurrent generation did not commit every local layer")
            }
            if let observer {
                try CBv2OwnerPhaseObservation(phase: .validationCommitEnd, tokenCount: tokenCount, committedTokens: committedTokens)
                    .deliver(to: observer, check: check)
            }
            return output
        } catch {
            isFailed = true
            // Forward's temporary transaction references have unwound before
            // the outer session calls retire; never reuse partially advanced KV.
            throw error
        }
    }

    func beginVerification(maximumSteps: Int, check: () throws -> Void) throws {
        do {
            try requireOpen(); try check()
            guard (1...2).contains(maximumSteps), maximumSteps <= maximumTokens - committedTokens else {
                throw ProbeError("Target verification exceeds the admitted request capacity")
            }
            try validateState(after: committedTokens); try check()
            verification = try .init(base: committedTokens, maximumSteps: maximumSteps, rows: rows)
        } catch { isFailed = true; throw error }
    }

    func stageVerification(check: () throws -> Void, additionalTargets: () -> [MLXArray],
        forward: ([any CBv2AttendingLayerCache], CBv2RecurrentStateEvaluation) throws -> MLXArray,
        validateOutput: (MLXArray) throws -> Void
    ) throws -> MLXArray {
        do {
            guard !isClosed, !isFailed, evaluation == nil, let verification else {
                throw ProbeError("No live target verification transaction")
            }
            return try verification.stage(recurrent: recurrent, bank: bank, rows: rows, check: check,
                additionalTargets: additionalTargets, forward: forward, validate: { output, frontier in
                    try validateOutput(output); try self.validateState(after: frontier)
                })
        } catch { isFailed = true; throw error }
    }

    func commitNextVerification(check: () throws -> Void) throws -> Int {
        do {
            guard !isClosed, !isFailed, evaluation == nil, let verification else {
                throw ProbeError("No target verification prefix can be committed")
            }
            let frontier = try verification.commitNext(check: check, validate: { committed, staged in
                // Pending suffix remains resident and visible to its existing
                // evaluation. Validate that physical frontier separately from
                // the oldest-first committed prefix; ordinary calls stay blocked.
                try self.validateState(after: staged)
                guard committed > self.committedTokens,
                      Set(self.recurrent.confirmedStateSnapshot()?.keys.map { $0 } ?? [])
                        == Set(self.geometry.recurrent.modelLayerIndices) else {
                    throw ProbeError("Target verification prefix lacks confirmed recurrent ownership")
                }
            })
            committedTokens = frontier
            return frontier
        } catch { isFailed = true; throw error }
    }

    func reconcileVerification(keeping count: Int, check: () throws -> Void) throws -> Int {
        do {
            guard !isClosed, !isFailed, evaluation == nil, let verification else {
                throw ProbeError("No target verification can be reconciled")
            }
            let frontier = try verification.reconcile(keeping: count, bank: bank, rows: rows,
                check: check, validate: { frontier in
                    try self.validateState(after: frontier)
                    guard Set(self.recurrent.confirmedStateSnapshot()?.keys.map { $0 } ?? [])
                        == Set(self.geometry.recurrent.modelLayerIndices) else {
                        throw ProbeError("Target verification did not reconcile every recurrent layer")
                    }
                })
            committedTokens = frontier; self.verification = nil
            return frontier
        } catch { isFailed = true; throw error }
    }

    func validateState(after count: Int) throws {
        if let layout = geometry.attentionLayout {
            try validateAttentionState(layout, after: count)
            return
        }
        for (index, optionalRow) in rows.enumerated() {
            guard let row = optionalRow, row.absoluteOffset == count, row.retainedCount == count,
                geometry.caches[index].rows.count == 1, geometry.caches[index].rows[0] === row,
                geometry.caches[index].positionOffsets.shape == [1],
                geometry.caches[index].positionOffsets.dtype == .int32,
                geometry.caches[index].positionOffsets.asArray(Int32.self) == [Int32(count)] else {
                throw ProbeError("CBv2 KV ownership or device token frontier differs")
            }
            let snapshot = row.snapshot(), kind = geometry.kinds[index]
            let shape = [1, kind.kvHeads, count, kind.headDim]
            guard snapshot.offset == count, snapshot.keys.shape == shape, snapshot.values.shape == shape,
                snapshot.keys.dtype == geometry.kvDType, snapshot.values.dtype == geometry.kvDType else {
                throw ProbeError("CBv2 KV shape/dtype differs from local model geometry")
            }
        }
        for layer in geometry.recurrent.layers {
            guard let state = recurrent.state(modelLayerIndex: layer.modelLayerIndex),
                let conv = state.conv, let ssm = state.ssm,
                conv.shape == layer.convShape, conv.dtype == layer.convDType,
                ssm.shape == layer.ssmShape, ssm.dtype == layer.ssmDType else {
                throw ProbeError("CBv2 conv/SSM shape or dtype differs from its local contract")
            }
        }
        guard backend.bytesInUse <= geometry.kvCapacityBytes else {
            throw ProbeError("CBv2 KV capacity exceeded the admitted geometry")
        }
    }

    /// Retirement discards the whole request; rollback of a pending recurrent
    /// generation is cleanup only and does not make advanced attention KV reusable.
    func retire(failed: Bool = false) throws {
        isFailed = isFailed || failed
        guard !isClosed else { return }
        Stream.gpu.synchronize(); Stream.cpu.synchronize()
        var cleanupError: Error?
        do { try verification?.discard() } catch { cleanupError = error }
        verification = nil
        if let evaluation, evaluationWasStaged {
            do { try evaluation.rollback() } catch { cleanupError = cleanupError ?? error }
        }
        evaluation = nil; evaluationWasStaged = false
        bank.releaseBoundRows()
        backend.release(rows); rows.removeAll()
        do { try recurrent.release() } catch { cleanupError = cleanupError ?? error }
        isClosed = true
        guard backend.bytesInUse == 0, backend.bytesReserved == 0,
            geometry.caches.allSatisfy({ $0.rows.isEmpty }), recurrent.isReleased else {
            isFailed = true
            throw cleanupError ?? ProbeError("CBv2 state retained ownership after retirement")
        }
        if let cleanupError { isFailed = true; throw cleanupError }
    }

    deinit { try? retire(failed: true) }
}
