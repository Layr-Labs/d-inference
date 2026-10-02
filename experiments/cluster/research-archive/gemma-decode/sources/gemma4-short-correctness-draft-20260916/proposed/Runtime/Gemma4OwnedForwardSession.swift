import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// Serialized real Gemma forward over the shared window-aware CBv2 owner.
/// The full reference and selected stages differ only in model dispatch; state
/// chronology, native evaluation, snapshots and retirement are the same core.
/// This low-level owner does not authorize registered memory use or transport.
final class Gemma4OwnedForwardSession {
    private let loaded: Gemma4LoadedForwardModel
    private let state: CBv2OwnedRequestState
    private let probe: Gemma4ForwardProbe
    private let residualDType: DType
    let request: QwenLayerStageGenerationRequest
    private var schedule: QwenLayerStageGenerationSchedule

    var committedTokens: Int { state.committedTokens }
    var isClosed: Bool { state.isClosed }
    var isFailed: Bool { state.isFailed }

    init(loaded: Gemma4LoadedForwardModel, request: QwenLayerStageGenerationRequest,
         probe: Gemma4ForwardProbe, residualDType: DType,
         admitGeometry: (CBv2RequestGeometry) throws -> Void,
         check: () throws -> Void) throws {
        try check(); try Gemma4ForwardRequest.validate(request, dtype: residualDType)
        guard probe.parameterLayoutSHA256 == loaded.receipt.parameterLayoutSHA256,
              probe.planSHA256 == loaded.plan.fingerprint,
              loaded.model.module.trainableParameters().flattened().isEmpty,
              loaded.model.isIngressStage ? probe.outgoingResidualDType == residualDType : true,
              loaded.model.isResidualConsumer ? probe.incomingResidualDType == residualDType : true else {
            throw ProbeError("Gemma model/probe/residual identity differs")
        }
        let caches = loaded.model.freshCaches()
        let geometry: CBv2RequestGeometry
        switch loaded.target {
        case .fullReference:
            geometry = try .init(attentionKinds: loaded.model.kinds, caches: caches,
                observed: probe.observed, globalLayerIndices: loaded.model.globals,
                maximumTokens: request.maximumTokens, maximumChunkTokens: request.chunkSize)
        case .stage(let rank):
            geometry = try .init(gemmaStage: loaded.plan.stages[rank], caches: caches,
                observed: probe.observed, maximumTokens: request.maximumTokens,
                maximumChunkTokens: request.chunkSize)
        }
        // Mandatory outer resource gate BEFORE any state storage is reserved.
        // Geometry includes mixed-type KV and window temporary terms, not MoE
        // kernel workspace or model/probe construction high-water.
        try admitGeometry(geometry); try check()
        self.state = try .init(geometry: geometry, promptCount: request.promptCount, outputCount: request.outputCount)
        self.loaded = loaded; self.request = request; self.probe = probe
        self.residualDType = residualDType; schedule = .init(request: request)
    }

    func prefillChunk(_ tokens: [Int], offset: Int, final: Bool,
                      incoming: Gemma4ForwardBoundary? = nil,
                      check: () throws -> Void) throws -> Gemma4ForwardOutput {
        do {
            try state.requireOpen()
            let frame = try schedule.admitPrefill(count: tokens.count, offset: offset, final: final)
            guard tokens == Array(request.promptTokenIDs[offset..<(offset + tokens.count)]) else {
                throw ProbeError("Gemma prefill differs from the pinned request IDs")
            }
            return try perform(tokens: tokens, frame: frame, incoming: incoming, check: check)
        } catch { try fail(error) }
    }

    func decode(_ token: Int, offset: Int, incoming: Gemma4ForwardBoundary? = nil,
                check: () throws -> Void) throws -> Gemma4ForwardOutput {
        do {
            try state.requireOpen()
            let frame = try schedule.admitDecode(offset: offset)
            return try perform(tokens: [token], frame: frame, incoming: incoming, check: check)
        } catch { try fail(error) }
    }

    private func perform(tokens: [Int], frame: QwenLayerStageFrame,
                         incoming: Gemma4ForwardBoundary?, check: () throws -> Void) throws -> Gemma4ForwardOutput {
        try MLX.withError { native in
            func checked() throws { try native.check(); try check(); try native.check() }
            do {
                try checked()
                guard tokens.allSatisfy({ (0..<request.profile.vocabularySize).contains($0) }),
                      state.committedTokens == schedule.committedTokens else {
                    throw ProbeError("Gemma input or committed frontier differs")
                }
                if loaded.model.isResidualConsumer {
                    guard let incoming, incoming.frame == frame,
                          incoming.requestSHA256 == request.fingerprint,
                          incoming.artifactSHA256 == loaded.receipt.artifactSHA256,
                          incoming.planSHA256 == loaded.plan.fingerprint,
                          incoming.mappingSHA256 == loaded.plan.conservation.fingerprint,
                          incoming.producerStageSHA256 == loaded.plan.stages[0].fingerprint,
                          incoming.tokenIDsSHA256 == qwenGenerationTokenHash(tokens) else {
                        throw ProbeError("Gemma incoming residual identity/frame differs")
                    }
                    try incoming.requireOwned(tokens: tokens.count, hidden: request.profile.hiddenSize, dtype: residualDType)
                } else if case .some = incoming { throw ProbeError("Gemma token ingress rejects a residual") }
                try checked()
                let output = try state.run(tokenCount: tokens.count, check: checked, forward: { caches, _ in
                    try self.loaded.model.forward(tokens: tokens, residual: incoming?.array,
                        frame: frame, caches: caches, nativeTypes: self.probe.observed.layerDTypes)
                }, validateOutput: { array in
                    let shape = self.loaded.model.isIngressStage ? [1, tokens.count, self.request.profile.hiddenSize]
                        : [1, frame.phase == .prefill && !frame.finalPromptChunk ? 1 : self.request.profile.vocabularySize]
                    guard array.shape == shape, [.float16, .bfloat16, .float32].contains(array.dtype),
                          !self.loaded.model.isIngressStage || array.dtype == self.residualDType else {
                        throw ProbeError("Gemma forward returned unexpected native shape/type")
                    }
                })
                try checked(); try schedule.commit(frame)
                if loaded.model.isIngressStage {
                    let payload = sha256(output.asData().data); try checked()
                    return .residual(.init(requestSHA256: request.fingerprint,
                        artifactSHA256: loaded.receipt.artifactSHA256, planSHA256: loaded.plan.fingerprint,
                        mappingSHA256: loaded.plan.conservation.fingerprint,
                        producerStageSHA256: loaded.plan.stages[0].fingerprint, frame: frame,
                        tokenIDsSHA256: qwenGenerationTokenHash(tokens), array: output, payloadSHA256: payload))
                }
                return frame.phase == .prefill && !frame.finalPromptChunk ? .evaluationHandle(output) : .logits(output)
            } catch { try native.check(); throw error }
        }
    }

    /// CPU metadata projection only. No array/cache owner leaves this session.
    func shortDiagnosticBinding() throws -> Gemma4ShortSessionBinding {
        try state.requireOpen()
        guard let layout = state.geometry.attentionLayout,
              layout.layers.map(\.element.rawValue) == probe.observed.layerDTypes.map({ String(describing: $0) }) else {
            throw ProbeError("Gemma diagnostic binding lacks actual matching native KV types")
        }
        return .init(target: loaded.receipt.target, planSHA256: loaded.plan.fingerprint,
            artifactSHA256: loaded.receipt.artifactSHA256, configurationSHA256: loaded.receipt.configurationSHA256,
            parameterLayoutSHA256: loaded.receipt.parameterLayoutSHA256, stateLayoutSHA256: layout.fingerprint,
            readAccountingSHA256: sha256(try canonicalJSONData(loaded.receipt.readAccounting)),
            selectedTensorCount: loaded.receipt.selectedTensorCount, selectedBytes: loaded.receipt.loadedTensorBytes,
            maximumTokens: layout.maximumTokens, maximumChunkTokens: layout.maximumChunkTokens,
            layers: layout.layers.enumerated().map { .init(localIndex: $0.offset, globalIndex: $0.element.globalIndex,
                kvHeads: $0.element.kvHeads, headDimension: $0.element.headDimension,
                window: $0.element.window ?? 0, dtype: $0.element.element.rawValue) },
            probePrefillTokens: 2, probeDecodeTokens: 1)
    }
    var shortLoadReceipt: Gemma4ForwardLoadReceipt { loaded.receipt }

    func snapshot(includeBytes: Bool = false, check: () throws -> Void) throws -> CBv2OwnedStateSnapshot {
        do {
            return try MLX.withError { native in
                try state.snapshot(globalLayerIndices: loaded.model.globals, includeBytes: includeBytes,
                    check: { try native.check(); try check(); try native.check() })
            }
        } catch { try fail(error) }
    }

    func finish(_ reason: QwenLayerStageGenerationFinishReason,
                selectedTokenCount: Int, lastTokenID: Int) throws {
        do {
            try state.requireOpen()
            try schedule.finish(reason, selectedTokenCount: selectedTokenCount, lastTokenID: lastTokenID)
            try retire(failed: false)
        } catch { try fail(error) }
    }
    func cancel() throws { try retire(failed: true) }

    private func retire(failed: Bool) throws {
        try MLX.withError { native in
            do { try state.retire(failed: failed); try native.check() }
            catch { try native.check(); throw error }
        }
    }
    private func fail(_ error: Error) throws -> Never {
        do { try retire(failed: true) }
        catch let cleanup { throw ProbeError("Gemma forward failed (\(error)); retirement failed (\(cleanup))") }
        throw error
    }
    deinit { try? retire(failed: !schedule.complete) }
}
