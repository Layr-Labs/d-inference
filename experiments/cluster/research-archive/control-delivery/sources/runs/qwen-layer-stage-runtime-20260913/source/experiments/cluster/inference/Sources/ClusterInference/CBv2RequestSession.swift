import MLX
import MLXLMCommon

/// One serialized, text-only request on the actual production CBv2 model
/// forward. No ordinary prepare/forward, scheduler, MTP, padding or prefix
/// adoption is involved. The caller owns rank agreement and the hard deadline.
final class CBv2RequestSession {
    private let adapter: CBv2SteppableLanguageModelAdapter
    private let geometry: CBv2RequestGeometry
    private let backend: CBv2ContiguousKVBackend
    private let bank: CBv2LayerCacheBank
    private let recurrent: CBv2RecurrentRequestState
    private var rows: [CBv2SequenceKV?]
    private var evaluation: CBv2RecurrentStateEvaluation?
    private var evaluationWasStaged = false
    private let vocabularySize: Int
    private let promptCount: Int
    private let outputCount: Int
    private var promptFinished = false
    private(set) var committedPromptTokens = 0
    private(set) var decodeForwardCount = 0
    private(set) var committedTokens = 0
    private(set) var isClosed = false
    private(set) var isFailed = false

    init(loaded: LoadedModel, promptCount: Int, outputCount: Int) throws {
        guard (1...32_768).contains(promptCount), (1...4096).contains(outputCount),
              promptCount <= 32_768 - outputCount else {
            throw ProbeError("cbv2-contiguous request exceeds its 32768-context/4096-output bound")
        }
        let geometry = try CBv2RequestGeometry(loaded: loaded, maximumTokens: promptCount + outputCount)
        let backend = CBv2ContiguousKVBackend(config: .init(
            bytesCapacity: geometry.kvCapacityBytes, kvDType: geometry.kvDType))
        let rows = try backend.makeSequenceState(layerKinds: geometry.kinds,
            promptLength: promptCount, maxLength: promptCount + outputCount)
        let recurrent = try CBv2RecurrentRequestState(spec: geometry.recurrent)
        guard rows.count == geometry.kinds.count,
              rows.allSatisfy({ $0?.absoluteOffset == 0 && $0?.retainedCount == 0 }),
              recurrent.confirmedStateSnapshot() == nil, recurrent.materializedByteCount == 0,
              !recurrent.isReleased else {
            backend.release(rows)
            throw ProbeError("CBv2 request did not start with fresh KV and recurrent ownership")
        }
        self.adapter = CBv2SteppableLanguageModelAdapter(loaded.model)
        self.geometry = geometry; self.backend = backend
        self.bank = CBv2LayerCacheBank(caches: geometry.caches)
        self.recurrent = recurrent; self.rows = rows
        self.vocabularySize = loaded.vocabularySize
        self.promptCount = promptCount; self.outputCount = outputCount
    }

    /// Intermediate chunks return an evaluated [1,1] handle. The final chunk
    /// returns evaluated [1,vocabulary] logits through the actual narrowing seam.
    func prefillChunk(_ tokens: [Int], final: Bool, check: () throws -> Void) throws -> MLXArray {
        do {
            try requireOpen()
            guard !promptFinished, !tokens.isEmpty,
                  tokens.count <= promptCount - committedPromptTokens,
                  final == (committedPromptTokens + tokens.count == promptCount) else {
                throw ProbeError("CBv2 prefill chunks do not match the agreed prompt frontier")
            }
            let output = try forward(tokens, requirement: final ? .lastPositionLogits : .evaluationOnly, check: check)
            committedPromptTokens += tokens.count
            promptFinished = final
            return output
        } catch { isFailed = true; throw error }
    }

    /// One consumed continuation token produces one evaluated [1,vocabulary]
    /// row. Exactly outputCount-1 decode forwards follow the prompt frontier.
    func decode(_ token: Int, check: () throws -> Void) throws -> MLXArray {
        do {
            try requireOpen()
            guard promptFinished, committedPromptTokens == promptCount,
                  decodeForwardCount < outputCount - 1 else {
                throw ProbeError("CBv2 decode is outside the agreed request schedule")
            }
            let output = try forward([token], requirement: nil, check: check)
            decodeForwardCount += 1
            return output
        } catch { isFailed = true; throw error }
    }

    private func requireOpen() throws {
        guard !isClosed, !isFailed, evaluation == nil else {
            throw ProbeError("CBv2 request is closed, failed, or has unfinished recurrent work")
        }
    }

    private func forward(_ tokens: [Int], requirement: CBv2PrefillRequirement?,
                         check: () throws -> Void) throws -> MLXArray {
        guard tokens.allSatisfy({ (0..<vocabularySize).contains($0) }) else {
            throw ProbeError("CBv2 input token is outside the vocabulary")
        }
        let caches = bank.layerCaches(rowStates: [rows])
        evaluation = try recurrent.bind()
        evaluationWasStaged = false
        let input = MLXArray(tokens.map(Int32.init)).reshaped([1, tokens.count])
        let output: MLXArray
        if let requirement {
            output = adapter.recurrentPrefill(tokens: input, inputEmbeddings: nil,
                caches: caches, recurrentState: [evaluation!], positionIds: nil, requirement: requirement)
        } else {
            output = adapter.forward(tokens: input, caches: caches,
                recurrentState: [evaluation!])[0..., -1, 0...]
        }
        let roots = try evaluation!.evaluate()
        evaluationWasStaged = true
        let cacheRoots = caches.flatMap { ($0 as! any KVCache).innerState() }
        // Mirrors EngineLoopV2.recurrentTargetForward + eagerCacheInnerState:
        // logits alone cannot stand in for conv/SSM and device-offset roots.
        eval([output] + roots + cacheRoots)
        try check()
        let width = requirement == .evaluationOnly ? 1 : vocabularySize
        guard output.shape == [1, width], [.float16, .bfloat16, .float32].contains(output.dtype) else {
            throw ProbeError("CBv2 forward returned unexpected logit/handle geometry")
        }
        try validateState(after: committedTokens + tokens.count)
        try evaluation!.commit()
        evaluation = nil; evaluationWasStaged = false
        committedTokens += tokens.count
        guard Set(recurrent.confirmedStateSnapshot()?.keys.map { $0 } ?? []) == Set(geometry.recurrent.modelLayerIndices) else {
            throw ProbeError("CBv2 recurrent generation was not committed completely")
        }
        return output
    }

    private func validateState(after count: Int) throws {
        for (index, optionalRow) in rows.enumerated() {
            guard let row = optionalRow, row.absoluteOffset == count, row.retainedCount == count,
                  geometry.caches[index].rows.count == 1,
                  geometry.caches[index].rows[0] === row,
                  geometry.caches[index].positionOffsets.shape == [1],
                  geometry.caches[index].positionOffsets.dtype == .int32,
                  geometry.caches[index].positionOffsets.asArray(Int32.self) == [Int32(count)] else {
                throw ProbeError("CBv2 row ownership or KV/device-position advancement differs")
            }
            let snapshot = row.snapshot()
            let kind = geometry.kinds[index]
            let shape = [1, kind.kvHeads, count, kind.headDim]
            guard snapshot.offset == count, snapshot.keys.shape == shape, snapshot.values.shape == shape,
                  snapshot.keys.dtype == geometry.kvDType, snapshot.values.dtype == geometry.kvDType else {
                throw ProbeError("CBv2 actual KV state differs from the local model geometry/dtype")
            }
        }
        for layer in geometry.recurrent.layers {
            guard let state = recurrent.state(modelLayerIndex: layer.modelLayerIndex),
                  let conv = state.conv, let ssm = state.ssm,
                  conv.shape == layer.convShape, conv.dtype == layer.convDType,
                  ssm.shape == layer.ssmShape, ssm.dtype == layer.ssmDType else {
                throw ProbeError("CBv2 staged conv/SSM state differs from the local model contract")
            }
        }
        guard backend.bytesInUse <= geometry.kvCapacityBytes else {
            throw ProbeError("CBv2 KV allocation exceeded the request's local geometry budget")
        }
    }

    /// Diagnostic CPU-owned snapshot; the baseline forward and state ownership
    /// remain independent from the layer-stage implementation.
    func snapshot(includeBytes: Bool = false, check: () throws -> Void) throws -> CBv2OwnedStateSnapshot {
        try requireOpen()
        try validateState(after: committedTokens)
        return try CBv2OwnedStateSnapshot.capture(geometry: geometry, rows: rows, recurrent: recurrent,
            committedTokens: committedTokens,
            globalLayerIndices: Array(0..<(geometry.kinds.count + geometry.recurrent.layers.count)),
            includeBytes: includeBytes, check: check)
    }

    /// Cleanup is idempotent and retires the entire request even when a forward
    /// failed. A stalled collective requires the outer process deadline; state
    /// is never declared reusable while device work is still in flight.
    func close() throws {
        guard !isClosed else { return }
        Stream.gpu.synchronize(); Stream.cpu.synchronize()
        var cleanupError: Error?
        if let evaluation, evaluationWasStaged {
            do { try evaluation.rollback() } catch { cleanupError = error }
        }
        evaluation = nil; evaluationWasStaged = false
        // Dropping an unstaged evaluation abandons its binding. The owner
        // outlives that unowned evaluation reference throughout cleanup.
        bank.releaseBoundRows()
        backend.release(rows); rows.removeAll()
        do { try recurrent.release() } catch { cleanupError = cleanupError ?? error }
        isClosed = true
        guard backend.bytesInUse == 0, backend.bytesReserved == 0,
              geometry.caches.allSatisfy({ $0.rows.isEmpty }), recurrent.isReleased else {
            isFailed = true
            throw cleanupError ?? ProbeError("CBv2 request ownership remained after retirement")
        }
        if let cleanupError { isFailed = true; throw cleanupError }
        guard isFailed || (promptFinished && committedPromptTokens == promptCount
                           && decodeForwardCount == outputCount - 1
                           && committedTokens == promptCount + outputCount - 1) else {
            isFailed = true
            throw ProbeError("CBv2 request closed before all agreed tokens were committed")
        }
    }

    deinit { try? close() }
}
