import Foundation
import MLX

/// The model and keyed data-plane half of the pure batch driver. All calls
/// run on the resident executor under its MLX error and resource scope.
final class MiMoNativeBatchExecutor: IndependentHistoryBatchExecutor {
    typealias Session = MiMoLayerStageSession
    private let stage: LoadedMiMoLayerStage
    private let admission: MiMoResidentAdmission
    private let collective: Collective
    private let records: QwenBatchRecordBinding
    private let check: () throws -> Void
    private let capacity: Int
    private var maximumCompletedDecodeWidth = 0

    init(stage: LoadedMiMoLayerStage, admission: MiMoResidentAdmission, collective: Collective,
         records: QwenBatchRecordBinding, capacity: Int, check: @escaping () throws -> Void) {
        self.stage = stage; self.admission = admission; self.collective = collective
        self.records = records; self.capacity = capacity; self.check = check
    }

    func open(lanes: Int) throws {
        let local = QwenBatchWire.Opening(lanes: lanes, pagedKV: true, prefixCacheEnabled: false,
            vocabularySize: admission.profile.vocabularySize, hiddenSize: admission.profile.hiddenSize)
        let sending = try records.opening(fromRank: collective.rank)
        let receiving = try records.opening(fromRank: 1 - collective.rank)
        let words: [Int32]
        if collective.rank == 0 {
            try send(local.words, scope: sending)
            words = try receive(local.words.count, scope: receiving)
        } else {
            words = try receive(local.words.count, scope: receiving)
            try send(local.words, scope: sending)
        }
        let peer = try QwenBatchWire.Opening(words: words)
        guard lanes == capacity, peer.lanes == lanes, peer.pagedKV, !peer.prefixCacheEnabled,
              peer.vocabularySize == local.vocabularySize, peer.hiddenSize == local.hiddenSize else {
            throw ProbeError("MiMo batch peers differ in width, storage or geometry")
        }
    }
    func session(_ request: QwenLayerStageGenerationRequest) throws -> MiMoLayerStageSession {
        let session = try MiMoLayerStageSession(stage: stage, plan: admission.plan,
            generationRequest: request, independentHistory: true)
        session.bindBatchMemoryObservation(scope: records.requestID)
        return session
    }
    func sendHeader(_ value: QwenBatchWire.Header) throws {
        try send(value.words, scope: records.header(step: value.step))
    }
    func receiveHeader(step: Int) throws -> QwenBatchWire.Header {
        try .init(words: receive(QwenBatchWire.headerWords, scope: records.header(step: step)), expectedStep: step, lanes: capacity)
    }
    func sendReply(_ value: QwenBatchWire.Reply) throws {
        try send(value.words, scope: records.reply(step: value.step))
    }
    func receiveReply(step: Int) throws -> QwenBatchWire.Reply {
        try .init(words: receive(QwenBatchWire.replyWords, scope: records.reply(step: step)), expectedStep: step, lanes: capacity)
    }

    func produceDecode(_ sessions: [MiMoLayerStageSession], tokens: [Int], lanes: [QwenBatchRecordBinding.Lane], step: Int) throws {
        let binding = try records.residual(step: step, kind: .decode, lanes: lanes)
        let residual = try MiMoLayerStageSession.decodeBatch(sessions, tokens: tokens, residual: nil, check: check)
        recordCompletedDecode(width: sessions.count)
        try sendResidual(residual, digest: sha256(residual.asData().data), records: binding)
    }
    func consumeDecode(_ sessions: [MiMoLayerStageSession], requests: [QwenLayerStageGenerationRequest], tokens: [Int],
                       lanes: [QwenBatchRecordBinding.Lane], step: Int) throws -> [Int] {
        let binding = try records.residual(step: step, kind: .decode, lanes: lanes)
        let incoming = try receiveResidual(shape: [sessions.count, 1, admission.profile.hiddenSize], records: binding)
        let logits = try MiMoLayerStageSession.decodeBatch(sessions, tokens: tokens, residual: incoming.array, check: check)
        recordCompletedDecode(width: sessions.count)
        // Shared finite-row validation precedes any request sampler advancing.
        // Every request retains its own sampler, seed and committed history.
        return try QwenResidentRuntime.selectBatchTokens(logits, requests: requests, check: check)
    }
    func producePrefill(_ session: MiMoLayerStageSession, request: QwenLayerStageGenerationRequest,
                        frame: QwenLayerStageFrame, lane: QwenBatchRecordBinding.Lane, step: Int) throws {
        let binding = try records.residual(step: step,
            kind: .prefill(offset: frame.tokenOffset, count: frame.tokenCount, final: frame.finalPromptChunk), lanes: [lane])
        let tokens = Array(request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)])
        guard case .hidden(let boundary) = try session.prefillChunk(tokens, offset: frame.tokenOffset,
                final: frame.finalPromptChunk, check: check) else {
            throw ProbeError("MiMo producer prefill did not return a residual")
        }
        try sendResidual(boundary.array, digest: boundary.payloadSHA256, records: binding)
    }
    func consumePrefill(_ session: MiMoLayerStageSession, request: QwenLayerStageGenerationRequest,
                        frame: QwenLayerStageFrame, lane: QwenBatchRecordBinding.Lane, step: Int) throws -> Int? {
        let binding = try records.residual(step: step,
            kind: .prefill(offset: frame.tokenOffset, count: frame.tokenCount, final: frame.finalPromptChunk), lanes: [lane])
        let incoming = try receiveResidual(shape: [1, frame.tokenCount, admission.profile.hiddenSize], records: binding)
        let tokens = Array(request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)])
        let identity = session.identity
        let boundary = QwenLayerStageBoundary(requestFingerprint: identity.requestFingerprint,
            sourceConfigurationSHA256: identity.sourceConfigurationSHA256,
            artifactAggregateSHA256: identity.artifactAggregateSHA256,
            storageCommitmentSHA256: identity.storageCommitmentSHA256, planFingerprint: identity.planFingerprint,
            producerStageFingerprint: admission.plan.stages[0].fingerprint, frame: frame,
            tokenIDsSHA256: QwenLayerStageBoundary.tokenHash(tokens), payloadSHA256: incoming.digest, array: incoming.array)
        switch try session.prefillChunk(tokens, offset: frame.tokenOffset, final: frame.finalPromptChunk,
                                       incoming: boundary, check: check) {
        case .evaluationHandle where !frame.finalPromptChunk: return nil
        case .logits(let row) where frame.finalPromptChunk:
            return try QwenLayerStageGenerationSelection.token(row, request: request, check: check)
        default: throw ProbeError("MiMo consumer prefill returned the wrong output kind")
        }
    }

    /// At most eight size-only observations per owner, after native evaluation.
    private func recordCompletedDecode(width: Int) {
        guard width > maximumCompletedDecodeWidth else { return }
        maximumCompletedDecodeWidth = width
        log("darkbloom-mimo-batch-decode-v1 rank=\(collective.rank)"
            + " scope=\(records.requestID.uuidString) width=\(width) capacity=\(capacity)")
    }

    private func send(_ words: [Int32], scope: CollectiveRecordScope) throws {
        _ = try collective.sendCompleted(MLXArray(words), to: 1 - collective.rank,
            maximumBytes: words.count * 4, scope: scope, check: check)
    }
    private func receive(_ count: Int, scope: CollectiveRecordScope) throws -> [Int32] {
        let array = try collective.receiveCompleted(shape: [count], dtype: .int32, from: 1 - collective.rank,
            maximumBytes: count * 4, scope: scope, check: check)
        let words = array.asArray(Int32.self); try check(); return words
    }
    private func sendResidual(_ array: MLXArray, digest: String, records: QwenBatchRecordBinding.ResidualRecords) throws {
        _ = try collective.sendCompleted(array, to: 1, maximumBytes: array.nbytes, scope: records.payload, check: check)
        try send(QwenResidentRuntime.digestWords(digest), scope: records.digest)
    }
    private func receiveResidual(shape: [Int], records: QwenBatchRecordBinding.ResidualRecords) throws -> (array: MLXArray, digest: String) {
        let bytes = try QwenLongPrefillCheckedBytes.product(shape + [stage.activationDType.size])
        let array = try collective.receiveCompleted(shape: shape, dtype: stage.activationDType, from: 0,
            maximumBytes: bytes, scope: records.payload, check: check)
        let digest = QwenResidentRuntime.digestHex(try receive(8, scope: records.digest))
        guard sha256(array.asData().data) == digest else { throw ProbeError("MiMo batch residual digest differs from its native payload") }
        try check(); return (array, digest)
    }
}
