import DarkbloomClusterProtocol
import MLX
import MLXLMCommon

/// Serialized state/evaluation core reusable by both ordinary and layer-stage
/// sessions. This owns no model, token schedule, output policy or returned arrays.
/// Callers must run native work inside MLX.withError and supply its check closure.
final class CBv2OwnedRequestState {
    let geometry: CBv2RequestGeometry
    /// The stage host's shared backend and bank when the geometry has a host
    /// (paged by default); otherwise this request's own contiguous storage.
    let backend: any CBv2KVBackend
    let bank: CBv2LayerCacheBank
    var hosted: Bool { geometry.host != nil }
    /// This request's rows, kept after release only to prove that no cache
    /// still binds them.
    private var releasedRows: [CBv2SequenceKV] = []
    let recurrent: CBv2RecurrentRequestState
    private(set) var rows: [CBv2SequenceKV?]
    private var evaluation: CBv2RecurrentStateEvaluation?
    private var evaluationWasStaged = false
    /// Width of the speculative window that is open, if one is, and how far
    /// its two-phase evaluation has gone.
    private var windowTokens: Int?
    private enum WindowPhase { case built, evaluated, settled }
    private var windowPhase: WindowPhase?
    private(set) var committedTokens = 0
    private(set) var isClosed = false
    private(set) var isFailed = false
    let maximumTokens: Int

    init(geometry: CBv2RequestGeometry, promptCount: Int, outputCount: Int) throws {
        guard (1...ClusterWorkerLimits.promptTokens).contains(promptCount), (1...ClusterWorkerLimits.outputTokens).contains(outputCount),
            promptCount <= ClusterWorkerLimits.contextTokens - outputCount else { throw ProbeError("CBv2 owned state exceeds the bounded request context") }
        let backend: any CBv2KVBackend = geometry.host?.backend ?? CBv2ContiguousKVBackend(config: .init(
            bytesCapacity: geometry.kvCapacityBytes, kvDType: geometry.kvDType))
        let rows = try backend.makeSequenceState(layerKinds: geometry.kinds,
            promptLength: promptCount, maxLength: promptCount + outputCount)
        let recurrent: CBv2RecurrentRequestState
        do { recurrent = try CBv2RecurrentRequestState(spec: geometry.recurrent) }
        catch { backend.release(rows); throw error }
        guard rows.count == geometry.kinds.count,
            rows.allSatisfy({ $0?.absoluteOffset == 0 && $0?.retainedCount == 0 }),
            // A host's caches may bind batchmates' rows; never these new ones.
            geometry.host != nil || geometry.caches.allSatisfy({ $0.rows.isEmpty }),
            recurrent.confirmedStateSnapshot() == nil, recurrent.materializedByteCount == 0,
            !recurrent.isReleased else {
            backend.release(rows); try? recurrent.release()
            throw ProbeError("CBv2 state did not start with exclusive fresh ownership")
        }
        self.geometry = geometry; self.backend = backend
        self.bank = geometry.host?.bank ?? CBv2LayerCacheBank(caches: geometry.caches)
        self.recurrent = recurrent; self.rows = rows
        self.maximumTokens = promptCount + outputCount
    }

    /// Adopts a complete committed state that another owner of the same stage
    /// geometry produced, instead of starting empty. The caller has already
    /// authenticated the arrays; this checks every shape and dtype against the
    /// local model geometry, copies the attention rows into rows this backend
    /// owns, and validates the result as a committed frontier. Attention arrays
    /// are keyed by the compact stage's own layer index, as recurrent ones are.
    /// `slidingTails`: each sliding-window layer's retained window at the
    /// frontier (its last `min(committed, window)` positions, oldest first),
    /// in place of a whole-history row.
    init(geometry: CBv2RequestGeometry, promptCount: Int, outputCount: Int,
         adoptingCommittedTokens committed: Int,
         attention: [Int: (keys: MLXArray, values: MLXArray)],
         slidingTails: [Int: (keys: MLXArray, values: MLXArray)] = [:],
         recurrent adopted: [Int: (conv: MLXArray, ssm: MLXArray)]) throws {
        guard (1...ClusterWorkerLimits.promptTokens).contains(promptCount), (1...ClusterWorkerLimits.outputTokens).contains(outputCount),
            promptCount <= ClusterWorkerLimits.contextTokens - outputCount, (1...(promptCount + outputCount)).contains(committed),
            attention.count + slidingTails.count == geometry.kinds.count,
            adopted.count == geometry.recurrent.layers.count else {
            throw ProbeError("CBv2 adopted state exceeds the bounded request context or its layer coverage differs")
        }
        var prefix: [(keys: MLXArray, values: MLXArray, offset: Int)?] = []
        for kind in geometry.kinds {
            let shape = [1, kind.kvHeads, kind.retainedTokens(atFrontier: committed), kind.headDim]
            let source: [Int: (keys: MLXArray, values: MLXArray)]
            if case .slidingWindow = kind.attention { source = slidingTails } else { source = attention }
            guard let layer = kind.modelLayerIndex, let pair = source[layer],
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
        let backend: any CBv2KVBackend = geometry.host?.backend ?? CBv2ContiguousKVBackend(config: .init(
            bytesCapacity: geometry.kvCapacityBytes, kvDType: geometry.kvDType))
        let rows: [CBv2SequenceKV?]
        if slidingTails.isEmpty {
            // Full attention only: the backend's own direct plan (paged writes the
            // arrays into fresh pages; contiguous copies them into its rows).
            rows = try backend.makeSequenceState(adopting: prefix, layerKinds: geometry.kinds,
                maxLength: promptCount + outputCount)
        } else {
            // A sliding row keeps only its window: fresh rows, each full row
            // written whole, each sliding row moved to its tail's first position
            // and written there, so ring slots, offset and oldest retained
            // position are what the original frames left.
            rows = try backend.makeSequenceState(layerKinds: geometry.kinds, promptLength: promptCount,
                maxLength: promptCount + outputCount)
            guard rows.count == geometry.kinds.count, rows.allSatisfy({ $0 != nil }) else {
                backend.release(rows)
                throw ProbeError("CBv2 adopted sliding state lacks a row per layer")
            }
            for (row, pair) in zip(rows, prefix) {
                guard let row, let pair else { continue }
                let first = committed - pair.keys.dim(2)
                if first > 0 { row.fastForward(to: first) }
                _ = row.update(keys: pair.keys, values: pair.values)
            }
        }
        let recurrent: CBv2RecurrentRequestState
        do { recurrent = try CBv2RecurrentRequestState(spec: geometry.recurrent, adoptedCommitted: layers) }
        catch { backend.release(rows); throw error }
        guard rows.count == geometry.kinds.count,
            zip(rows, geometry.kinds).allSatisfy({ row, kind in
                row?.absoluteOffset == committed && row?.retainedCount == kind.retainedTokens(atFrontier: committed)
            }),
            geometry.host != nil || geometry.caches.allSatisfy({ $0.rows.isEmpty }),
            Set(recurrent.confirmedStateSnapshot()?.keys.map { $0 } ?? []) == Set(geometry.recurrent.modelLayerIndices),
            !recurrent.isReleased else {
            backend.release(rows); try? recurrent.release()
            throw ProbeError("CBv2 adopted state did not take exclusive ownership at its frontier")
        }
        self.geometry = geometry; self.backend = backend
        self.bank = geometry.host?.bank ?? CBv2LayerCacheBank(caches: geometry.caches)
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
        guard !isClosed, !isFailed, evaluation == nil, windowPhase == nil else {
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
            try validateState(after: committedTokens + tokenCount, storageViews: !pagedHost)
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

    /// A speculative window: `tokenCount` tokens run through the stage with
    /// every recurrent layer capturing its state per position, and nothing is
    /// committed. Used only by a decoding rank that verifies drafted tokens.
    ///
    /// Two phases, so a caller can evaluate several stages' windows (and the
    /// drafter's state) in one evaluation: `beginWindow` builds the graph and
    /// returns its outputs and the roots that must be evaluated with them;
    /// after the caller's `eval`, `confirmWindow` checks what the evaluation
    /// left. `settleWindow` then keeps a prefix, again in two phases.
    func beginWindow(tokenCount: Int,
                     forward: ([any CBv2AttendingLayerCache], CBv2RecurrentStateEvaluation) throws -> [MLXArray]
    ) throws -> (outputs: [MLXArray], roots: [MLXArray]) {
        do {
            try requireOpen()
            guard windowTokens == nil, windowPhase == nil, tokenCount > 0,
                  tokenCount <= maximumTokens - committedTokens else {
                throw ProbeError("CBv2 speculative window exceeds the admitted capacity")
            }
            let caches = bank.layerCaches(rowStates: [rows])
            evaluation = try recurrent.bind(); evaluationWasStaged = false
            let outputs = try Self.buildingWindow(bank: bank, pagedHost: pagedHost) {
                try forward(caches, evaluation!)
            }
            let recurrentRoots = try evaluation!.evaluate(); evaluationWasStaged = true
            guard evaluation!.isCaptured else {
                throw ProbeError("CBv2 speculative window did not capture its recurrent positions")
            }
            let cacheRoots = caches.flatMap { ($0 as! any KVCache).innerState() }
            windowTokens = tokenCount; windowPhase = .built
            return (outputs, recurrentRoots + cacheRoots)
        } catch {
            isFailed = true
            throw error
        }
    }

    /// Builds a speculative window's forward. On a paged host every layer
    /// cache attends the `1 + k` window one query column at a time (the
    /// one-token decode kernel per column), as the single-Mac engine's MTP
    /// verification round does, with the columns of a one-request window
    /// dispatched together (`PagedMTPBatchedColumns`: independent decode rows
    /// of the same kernel, one launch; the cache falls back to one launch
    /// per column where that is ineligible); otherwise a paged cache serves
    /// the window as a prompt chunk and re-gathers the request's whole
    /// history from its pages per attention layer per round, which made MTP
    /// decode collapse with context (9B at 30K: 25.7 vs 133 tok/s
    /// contiguous). Contiguous storage keeps the window it always had.
    static func buildingWindow<R>(bank: CBv2LayerCacheBank, pagedHost: Bool,
                                  _ forward: () throws -> R) throws -> R {
        guard pagedHost else { return try forward() }
        guard bank.supportsMTPRectangularVerification else {
            throw ProbeError("Paged stage KV cannot serialise a speculative window")
        }
        return try bank.withMTPRectangularVerification(batched: true, forward)
    }

    /// After the caller evaluated the roots `beginWindow` returned.
    func confirmWindow(check: () throws -> Void) throws {
        do {
            guard !isClosed, !isFailed, let total = windowTokens, windowPhase == .built,
                  evaluation != nil, evaluationWasStaged else {
                throw ProbeError("CBv2 speculative window was not built")
            }
            try check()
            for optionalRow in rows {
                guard let row = optionalRow, row.supportsSpeculativeWrites,
                      row.absoluteOffset == committedTokens + total else {
                    throw ProbeError("CBv2 speculative window left an attention row it cannot roll back exactly")
                }
            }
            windowPhase = .evaluated
        } catch {
            isFailed = true
            throw error
        }
    }

    /// Commits the first `kept` tokens of the evaluated window and discards
    /// the rest: the recurrent state at that position, the attention rows
    /// rolled back by the remainder. Returns the roots to evaluate before
    /// `confirmSettled`.
    func settleWindow(keeping kept: Int) throws -> [MLXArray] {
        do {
            guard !isClosed, !isFailed, let evaluation, evaluationWasStaged,
                  let total = windowTokens, windowPhase == .evaluated, (1...total).contains(kept) else {
                throw ProbeError("CBv2 speculative window is not open or keeps an impossible prefix")
            }
            try evaluation.commit(keepPositions: kept)
            self.evaluation = nil; evaluationWasStaged = false; windowTokens = nil
            if kept < total {
                for row in rows { row?.rollback(total - kept) }
                // The caches' device offsets ran ahead with the window.
                bank.invalidateBoundComposition()
            }
            committedTokens += kept
            _ = bank.layerCaches(rowStates: [rows])
            // The kept state is a selection from the window; make it the only
            // thing retained before the window's arrays are dropped.
            var roots: [MLXArray] = geometry.caches.map { $0.positionOffsets }
            for layer in geometry.recurrent.layers {
                guard let state = recurrent.state(modelLayerIndex: layer.modelLayerIndex),
                      let conv = state.conv, let ssm = state.ssm else {
                    throw ProbeError("CBv2 speculative window committed no state for a recurrent layer")
                }
                roots.append(conv); roots.append(ssm)
            }
            windowPhase = .settled
            return roots
        } catch {
            isFailed = true
            throw error
        }
    }

    /// After the caller evaluated the roots `settleWindow` returned.
    func confirmSettled(check: () throws -> Void) throws {
        do {
            guard !isClosed, !isFailed, windowPhase == .settled, evaluation == nil else {
                throw ProbeError("CBv2 speculative window was not settled")
            }
            try check()
            try validateState(after: committedTokens, storageViews: !pagedHost)
            guard Set(recurrent.confirmedStateSnapshot()?.keys.map { $0 } ?? [])
                == Set(geometry.recurrent.modelLayerIndices) else {
                throw ProbeError("CBv2 speculative window did not commit every local layer")
            }
            windowPhase = nil
            try check()
        } catch {
            isFailed = true
            throw error
        }
    }

    /// A paged host's row snapshot is a WHOLE-HISTORY page gather per attention
    /// layer, and the gather publishes the pool's fence, so the next step's
    /// writes make the GPU execute it: after every decode token it cost the
    /// one-request worker 6-12 % of its decode rate, and after every prompt
    /// chunk and every speculative window it re-read the whole context once per
    /// layer (O(context) per chunk and per verify round). On a paged host every
    /// step checks each row's frontier and binding; the attendable views' shape
    /// and dtype are checked at adoption. Contiguous hosts keep every check.
    var pagedHost: Bool { geometry.host?.kind == .paged }

    /// The frontier a cache's `positionOffsets` holds. A paged cache keeps the
    /// host values its device array is advanced by (item 25: the per-layer
    /// `asArray` was a host read per attention layer per step on the decode
    /// path); full validation (`deviceRead`, adoption and contiguous hosts)
    /// still reads the device array, and checks the host mirror against it.
    static func frontier(of cache: any CBv2AttendingLayerCache, deviceRead: Bool) -> [Int32]? {
        guard let paged = cache as? PagedLayerCache else {
            return cache.positionOffsets.asArray(Int32.self)
        }
        guard deviceRead else { return paged.hostPositionOffsets }
        let device = cache.positionOffsets.asArray(Int32.self)
        return device == paged.hostPositionOffsets ? device : nil
    }

    func validateState(after count: Int, storageViews: Bool = true) throws {
        // A host's caches are shared: bind this request's rows (a no-op when
        // they are bound already) before checking what the caches hold.
        if hosted { _ = bank.layerCaches(rowStates: [rows]) }
        for (index, optionalRow) in rows.enumerated() {
            let kind = geometry.kinds[index], retained = kind.retainedTokens(atFrontier: count)
            let cache = geometry.caches[index]
            guard let row = optionalRow, row.absoluteOffset == count, row.retainedCount == retained,
                cache.rows.count == 1, cache.rows[0] === row,
                cache.positionOffsets.shape == [1], cache.positionOffsets.dtype == .int32,
                Self.frontier(of: cache, deviceRead: storageViews) == [Int32(count)] else {
                throw ProbeError("CBv2 KV ownership or device token frontier differs")
            }
            guard storageViews else { continue }
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
        // A host's pool holds every lane; its own reservations bound it.
        guard hosted || backend.bytesInUse <= geometry.kvCapacityBytes else {
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
        evaluation = nil; evaluationWasStaged = false; windowTokens = nil; windowPhase = nil
        if PagedLayerCache.engineTrace, pagedHost {
            // Diagnosis only (cumulative per host cache): which paged paths served the request.
            let paged: [PagedLayerCache] = geometry.caches.compactMap { $0 as? PagedLayerCache }
            var multiQuery = 0, batched = 0, gathers = 0, mirrorChunks = 0
            for cache in paged {
                multiQuery += cache.mtpMultiQueryCalls; batched += cache.mtpBatchedAttentionCalls
                gathers += cache.prefillHistoryGathers; mirrorChunks += cache.prefillMirrorChunks
            }
            let plan: String = paged.first?.segmentDispatchTrace ?? "-"
            var line = "darkbloom-paged-engine-trace-v1 committed=\(committedTokens) layers=\(paged.count)"
            line += " mq_windows=\(multiQuery) batched_windows=\(batched)"
            line += " prefill_gathers=\(gathers) mirror_chunks=\(mirrorChunks) plan0=\(plan)"
            log(line)
        }
        bank.releaseBoundRows()
        releasedRows = rows.compactMap { $0 }
        backend.release(rows); rows.removeAll()
        do { try recurrent.release() } catch { cleanupError = cleanupError ?? error }
        isClosed = true
        // A host's pool may still hold other lanes: this request's own rows
        // must be unbound everywhere; its own storage alone must be empty.
        let unbound = geometry.caches.allSatisfy { cache in
            !cache.rows.contains { row in releasedRows.contains { $0 === row } }
        }
        let empty = hosted ? unbound : backend.bytesInUse == 0 && backend.bytesReserved == 0
            && geometry.caches.allSatisfy({ $0.rows.isEmpty })
        releasedRows.removeAll()
        guard empty, recurrent.isReleased else {
            isFailed = true
            throw cleanupError ?? ProbeError("CBv2 state retained ownership after retirement")
        }
        if let cleanupError { isFailed = true; throw cleanupError }
    }

    deinit { try? retire(failed: true) }
}

extension CBv2OwnedRequestState {
    /// One frame of `tokenCount` tokens for several requests of the same
    /// hosted stage at once (continuous batching): every request's rows are
    /// bound to the host's caches in the order given, every request binds its
    /// own recurrent evaluation, and one forward computes all of them. Each
    /// row attends only its own KV (both backends dispatch attention per row);
    /// the shared projections round two or more rows differently from one
    /// (MLX `qmv_wide`), identically for every batch size from two up.
    ///
    /// Any failure marks every request failed; the caller retires them all.
    static func runBatch(_ states: [CBv2OwnedRequestState], tokenCount: Int, check: () throws -> Void,
                         forward: ([any CBv2AttendingLayerCache], [CBv2RecurrentStateEvaluation]) throws -> MLXArray,
                         validateOutput: (MLXArray) throws -> Void) throws -> MLXArray {
        guard let host = states.first?.geometry.host, states.count <= host.lanes,
              states.allSatisfy({ $0.geometry.host === host }),
              Set(states.map { ObjectIdentifier($0) }).count == states.count else {
            states.forEach { $0.isFailed = true }
            throw ProbeError("A batched frame needs distinct requests of one stage KV host, within its lanes")
        }
        do {
            for state in states {
                try state.requireOpen()
                guard tokenCount > 0, tokenCount <= state.maximumTokens - state.committedTokens else {
                    throw ProbeError("CBv2 batched advance exceeds a request's admitted capacity")
                }
            }
            let caches = host.bank.layerCaches(rowStates: states.map(\.rows))
            for state in states {
                state.evaluation = try state.recurrent.bind(); state.evaluationWasStaged = false
            }
            let output = try forward(caches, states.map { $0.evaluation! })
            var roots: [MLXArray] = []
            for state in states {
                roots += try state.evaluation!.evaluate(); state.evaluationWasStaged = true
            }
            let cacheRoots = caches.flatMap { ($0 as! any KVCache).innerState() }
            eval([output] + roots + cacheRoots)
            try check()
            try validateOutput(output)
            let frontiers = states.map { Int32($0.committedTokens + tokenCount) }
            for (index, cache) in caches.enumerated() {
                guard cache.rows.count == states.count, cache.positionOffsets.shape == [states.count],
                      cache.positionOffsets.dtype == .int32, cache.positionOffsets.asArray(Int32.self) == frontiers,
                      host.owns(cache, at: index) else {
                    throw ProbeError("CBv2 batched KV binding or device token frontiers differ")
                }
            }
            for (lane, state) in states.enumerated() {
                try state.validateBatchRow(lane: lane, after: state.committedTokens + tokenCount)
            }
            try check()
            for state in states {
                try state.evaluation!.commit()
                state.evaluation = nil; state.evaluationWasStaged = false
                state.committedTokens += tokenCount
                guard Set(state.recurrent.confirmedStateSnapshot()?.keys.map { $0 } ?? [])
                    == Set(state.geometry.recurrent.modelLayerIndices) else {
                    throw ProbeError("CBv2 batched recurrent generation did not commit every local layer")
                }
            }
            return output
        } catch {
            states.forEach { $0.isFailed = true }
            throw error
        }
    }

    /// One request's rows after a batched frame: each at the new frontier and
    /// bound at its own lane of every cache.
    private func validateBatchRow(lane: Int, after count: Int) throws {
        for (index, optionalRow) in rows.enumerated() {
            let kind = geometry.kinds[index], retained = kind.retainedTokens(atFrontier: count)
            let cache = geometry.caches[index]
            guard let row = optionalRow, row.absoluteOffset == count, row.retainedCount == retained,
                  cache.rows.indices.contains(lane), cache.rows[lane] === row else {
                throw ProbeError("CBv2 batched KV ownership or token frontier differs")
            }
        }
        for layer in geometry.recurrent.layers {
            guard let state = recurrent.state(modelLayerIndex: layer.modelLayerIndex),
                let conv = state.conv, let ssm = state.ssm,
                conv.shape == layer.convShape, conv.dtype == layer.convDType,
                ssm.shape == layer.ssmShape, ssm.dtype == layer.ssmDType else {
                throw ProbeError("CBv2 batched conv/SSM shape or dtype differs from its local contract")
            }
        }
    }
}
