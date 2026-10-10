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
    private var evaluationWasStaged = false
    private(set) var committedTokens = 0
    private(set) var isClosed = false
    private(set) var isFailed = false
    let maximumTokens: Int

    init(geometry: CBv2RequestGeometry, promptCount: Int, outputCount: Int) throws {
        guard (1...32_768).contains(promptCount), (1...4096).contains(outputCount),
            promptCount <= 32_768 - outputCount else { throw ProbeError("CBv2 owned state exceeds the bounded request context") }
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

    /// Adopts a complete committed state that another owner of the same stage
    /// geometry produced, instead of starting empty. The caller has already
    /// authenticated the arrays; this checks every shape and dtype against the
    /// local model geometry, copies the attention rows into rows this backend
    /// owns, and validates the result as a committed frontier. Attention arrays
    /// are keyed by the compact stage's own layer index, as recurrent ones are.
    init(geometry: CBv2RequestGeometry, promptCount: Int, outputCount: Int,
         adoptingCommittedTokens committed: Int,
         attention: [Int: (keys: MLXArray, values: MLXArray)],
         recurrent adopted: [Int: (conv: MLXArray, ssm: MLXArray)]) throws {
        guard (1...32_768).contains(promptCount), (1...4096).contains(outputCount),
            promptCount <= 32_768 - outputCount, (1...(promptCount + outputCount)).contains(committed),
            attention.count == geometry.kinds.count, adopted.count == geometry.recurrent.layers.count else {
            throw ProbeError("CBv2 adopted state exceeds the bounded request context or its layer coverage differs")
        }
        var prefix: [(keys: MLXArray, values: MLXArray, offset: Int)?] = []
        for kind in geometry.kinds {
            let shape = [1, kind.kvHeads, committed, kind.headDim]
            guard let layer = kind.modelLayerIndex, let pair = attention[layer],
                pair.keys.shape == shape, pair.values.shape == shape,
                pair.keys.dtype == geometry.kvDType, pair.values.dtype == geometry.kvDType else {
                throw ProbeError("CBv2 adopted KV shape/dtype differs from local model geometry")
            }
            prefix.append((keys: pair.keys, values: pair.values, offset: committed))
        }
        var layers: [Int: CBv2RecurrentLayerState] = [:]
        for layer in geometry.recurrent.layers {
            guard let pair = adopted[layer.modelLayerIndex],
                pair.conv.shape == layer.convShape, pair.conv.dtype == layer.convDType,
                pair.ssm.shape == layer.ssmShape, pair.ssm.dtype == layer.ssmDType else {
                throw ProbeError("CBv2 adopted conv/SSM shape or dtype differs from its local contract")
            }
            layers[layer.modelLayerIndex] = .init(conv: pair.conv, ssm: pair.ssm)
        }
        let backend = CBv2ContiguousKVBackend(config: .init(
            bytesCapacity: geometry.kvCapacityBytes, kvDType: geometry.kvDType))
        let rows = try backend.makeSequenceState(adopting: prefix, layerKinds: geometry.kinds,
            maxLength: promptCount + outputCount)
        let recurrent: CBv2RecurrentRequestState
        do { recurrent = try CBv2RecurrentRequestState(spec: geometry.recurrent, adoptedCommitted: layers) }
        catch { backend.release(rows); throw error }
        guard rows.count == geometry.kinds.count,
            rows.allSatisfy({ $0?.absoluteOffset == committed && $0?.retainedCount == committed }),
            geometry.caches.allSatisfy({ $0.rows.isEmpty }),
            Set(recurrent.confirmedStateSnapshot()?.keys.map { $0 } ?? []) == Set(geometry.recurrent.modelLayerIndices),
            !recurrent.isReleased else {
            backend.release(rows); try? recurrent.release()
            throw ProbeError("CBv2 adopted state did not take exclusive ownership at its frontier")
        }
        self.geometry = geometry; self.backend = backend
        self.bank = CBv2LayerCacheBank(caches: geometry.caches)
        self.recurrent = recurrent; self.rows = rows
        self.maximumTokens = promptCount + outputCount
        self.committedTokens = committed
        // From here deinit retires whatever a failed check leaves behind.
        // Bind the rows as a forward would and materialize the copies, so the
        // adopted arrays are no longer referenced by a lazy assignment.
        _ = bank.layerCaches(rowStates: [rows])
        eval(rows.compactMap { $0 }.flatMap { row -> [MLXArray] in
            let snapshot = row.snapshot()
            return [snapshot.keys, snapshot.values]
        } + geometry.caches.map { $0.positionOffsets })
        try validateState(after: committed)
    }

    func requireOpen() throws {
        guard !isClosed, !isFailed, evaluation == nil else {
            throw ProbeError("CBv2 state is retired, failed or has unfinished work")
        }
    }

    func run(tokenCount: Int, observer: CBv2OwnerPhaseObserver? = nil, check: () throws -> Void,
             forward: ([any CBv2AttendingLayerCache], CBv2RecurrentStateEvaluation) throws -> MLXArray,
             validateOutput: (MLXArray) throws -> Void) throws -> MLXArray {
        do {
            try requireOpen()
            guard tokenCount > 0, tokenCount <= maximumTokens - committedTokens else {
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
            eval([output] + recurrentRoots + cacheRoots)
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

    func validateState(after count: Int) throws {
        for (index, optionalRow) in rows.enumerated() {
            let kind = geometry.kinds[index], retained = kind.retainedTokens(atFrontier: count)
            guard let row = optionalRow, row.absoluteOffset == count, row.retainedCount == retained,
                geometry.caches[index].rows.count == 1, geometry.caches[index].rows[0] === row,
                geometry.caches[index].positionOffsets.shape == [1],
                geometry.caches[index].positionOffsets.dtype == .int32,
                geometry.caches[index].positionOffsets.asArray(Int32.self) == [Int32(count)] else {
                throw ProbeError("CBv2 KV ownership or device token frontier differs")
            }
            let snapshot = row.snapshot()
            let shape = [1, kind.kvHeads, retained, kind.headDim]
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
        if let evaluation, evaluationWasStaged {
            do { try evaluation.rollback() } catch { cleanupError = error }
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
