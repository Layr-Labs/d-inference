import Foundation
import MLX
import MLXLLM

/// One serialized request on one verified GLM stage. The binding supplies the
/// loaded model's identity; both ranks negotiate the same stage contract.
/// A producer commits only after its consumer callback acknowledges the frame;
/// a receiver commits before its transport sends that acknowledgement.
/// Registration, memory admission and distributed retirement remain the owner's
/// responsibility. This session alone does not establish a serving capability.
final class GLM5NextStageSession {
    let identity: QwenLayerStageSessionIdentity
    let agreement: QwenLayerStageGenerationAgreement
    private let model: GLM5NextTextStage
    private var cache: GLM5NextTextStageCache?
    private var schedule: QwenLayerStageGenerationSchedule
    private var inOperation = false
    /// This request's prompt-prefix capture, when its plan keeps one.
    var prefixCapture: ClusterStagePrefixCapture?
    var imageFeatures: GLM5NextStageImageFeatures?
    private(set) var isFailed = false
    private(set) var isClosed = false
    var committedTokens: Int { schedule.committedTokens }

    /// `restoring` starts the stage from its own cached state at the agreed
    /// reused prefix (`request.reusedPrefixTokens`); without it the request
    /// starts cold.
    init(stage: GLM5NextStageBinding, agreement: QwenLayerStageGenerationAgreement,
         restoring: QwenStagePrefixState? = nil) throws {
        let identity = try stage.identity(for: agreement), model = stage.model
        let request = agreement.request, profile = request.profile
        let descriptor = agreement.descriptor, c = model.plan.configuration
        guard (0...1).contains(identity.stageIndex),
              model.plan.isFirst == (identity.stageIndex == 0),
              model.plan.isFinal == (identity.stageIndex == 1),
              profile.residualStreams == c.hcMult, c.hcMult == 4,
              profile.hiddenSize == c.hiddenSize, profile.vocabularySize == c.vocabularySize,
              profile.activationDType == c.dtype, profile.selectedRowDType == c.dtype,
              request.maximumTokens <= c.maxPositionEmbeddings,
              request.reusedPrefixTokens == (restoring?.committedTokens ?? 0), !request.decodingRankAlone,
              request.stillImages == nil || (restoring == nil && request.reusedPrefixTokens == 0),
              agreement.phaseSplit == nil, !agreement.compactDecode,
              agreement.speculativeHead == nil, agreement.speculativeRoundsFraming == nil,
              identity.requestFingerprint == request.fingerprint,
              identity.artifactAggregateSHA256 == descriptor.artifactAggregateSHA256,
              identity.sourceConfigurationSHA256 == descriptor.sourceConfigurationSHA256,
              identity.storageCommitmentSHA256 == descriptor.storageCommitmentSHA256,
              identity.planFingerprint == descriptor.planFingerprint,
              identity.stageFingerprint == descriptor.stageFingerprints[identity.stageIndex],
              identity.activationDType == profile.activationDType,
              !identity.bf16ConversionEnabled else {
            throw ProbeError("GLM stage, loaded identity or request agreement differs")
        }
        let dtype: DType
        switch profile.activationDType {
        case "bfloat16": dtype = .bfloat16
        case "float32": dtype = .float32
        case "float16": dtype = .float16
        default: throw ProbeError("GLM stage boundary dtype is unsupported")
        }
        _ = try qwenGenerationBoundaryGeometry(request: request, dtype: dtype, authenticatedChunking: true)
        self.model = model; self.identity = identity; self.agreement = agreement
        let fresh = model.newCache()
        if let restoring {
            try MLX.withError { error in
                try GLM5NextStagePrefixSnapshot.restore(restoring, into: fresh.layers, globalLayers: Array(model.plan.layers))
                try error.check()
            }
        }
        cache = fresh; schedule = .init(request: request)
        guard fresh.offset == schedule.committedTokens else {
            throw ProbeError("GLM restored stage frontier differs from the planned request")
        }
    }

    /// `afterEvaluation` runs with evaluated, joined native storage while the
    /// cache is still tentative. On rank 0 it must send the complete four-stream
    /// boundary and wait for boundaryConsumed. A throw poisons this request and
    /// leaves its committed cache/frontier unchanged.
    func forward(frame: QwenLayerStageFrame, tokens: [Int],
                 incoming: QwenLayerStageBoundary? = nil,
                 afterEvaluation: (QwenLayerStageOutput) throws -> Void,
                 check: () throws -> Void) throws -> QwenLayerStageOutput {
        guard !isClosed, !isFailed, !inOperation, let cache else {
            throw ProbeError("GLM stage request is retired, failed or already executing")
        }
        inOperation = true
        defer { inOperation = false }
        do {
            return try MLX.withError { error in
                func checked() throws {
                    try error.check(); try check()
                    guard !isFailed else { throw ProbeError("GLM stage request was invalidated") }
                }
                guard frame == (try agreement.request.frame(sequence: frame.sequence)),
                      frame.tokenOffset == committedTokens, tokens.count == frame.tokenCount,
                      tokens.allSatisfy({ (0..<agreement.request.profile.vocabularySize).contains($0) }),
                      cache.offset == committedTokens else {
                    throw ProbeError("GLM frame differs from its local native frontier")
                }
                if frame.phase == .prefill {
                    guard tokens == Array(agreement.request.promptTokenIDs[
                        frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)]) else {
                        throw ProbeError("GLM prefill tokens differ from the admitted prompt")
                    }
                }
                // Validate the schedule before preparing native work. Publishing
                // the already-validated value cannot throw after the cache commit.
                var nextSchedule = schedule
                try nextSchedule.commit(frame)
                try checked()
                // The validated schedule admits readout only at the prompt end
                // and decode. Earlier chunks still fence every hidden/cache root.
                let needsLogits = frame.phase == .decode || frame.finalPromptChunk
                let candidate: GLM5NextTextStageCandidate
                if identity.stageIndex == 0 {
                    guard incoming == nil else { throw ProbeError("GLM producer cannot consume a boundary") }
                    if let media = agreement.request.stillImages, frame.phase == .prefill {
                        guard let imageFeatures, imageFeatures.media == media else {
                            throw ProbeError("GLM image request lacks its exact feature owner")
                        }
                        if frame.tokenOffset == 0 { try imageFeatures.prepare(check: checked) }
                        let embeddings = try imageFeatures.embeddings(tokens: tokens, offset: frame.tokenOffset, model: model)
                        candidate = try model.prepareForward(embeddings: embeddings, cache: cache)
                    } else {
                        candidate = try model.prepareForward(
                            tokens: MLXArray(tokens.map(Int32.init), [1, tokens.count]), cache: cache)
                    }
                } else {
                    guard let incoming else { throw ProbeError("GLM consumer requires all four residual streams") }
                    try validate(incoming, frame: frame, tokens: tokens)
                    candidate = try model.prepareForward(streams: incoming.array, cache: cache,
                        readout: needsLogits ? .lastToken : .none)
                }
                var result: QwenLayerStageOutput?
                try candidate.commit { roots in
                    eval(roots)
                    Stream.gpu.synchronize()
                    try checked()
                    let output: QwenLayerStageOutput
                    switch candidate.output {
                    case .streams(let array):
                        guard identity.stageIndex == 0 else { throw ProbeError("GLM consumer returned streams") }
                        let boundary = QwenLayerStageBoundary(
                            requestFingerprint: identity.requestFingerprint,
                            sourceConfigurationSHA256: identity.sourceConfigurationSHA256,
                            artifactAggregateSHA256: identity.artifactAggregateSHA256,
                            storageCommitmentSHA256: identity.storageCommitmentSHA256,
                            planFingerprint: identity.planFingerprint,
                            producerStageFingerprint: identity.stageFingerprint,
                            frame: frame, tokenIDsSHA256: QwenLayerStageBoundary.tokenHash(tokens),
                            payloadSHA256: sha256(array.asData().data), array: array)
                        try boundary.validateOwnedArray(tokens: tokens.count,
                            hidden: agreement.request.profile.hiddenSize, dtype: array.dtype, residualStreams: 4)
                        output = .hidden(boundary)
                    case .hidden(let hidden):
                        guard identity.stageIndex == 1, !needsLogits else {
                            throw ProbeError("GLM hidden-only result differs from the admitted readout")
                        }
                        output = .evaluationHandle(hidden)
                    case .final(let value):
                        guard identity.stageIndex == 1, needsLogits,
                              value.logits.shape == [1, 1, agreement.request.profile.vocabularySize] else {
                            throw ProbeError("GLM final result differs from the admitted readout")
                        }
                        let row = value.logits[0..., -1, 0...]
                        eval(row); Stream.gpu.synchronize(); try checked()
                        guard row.shape == [1, agreement.request.profile.vocabularySize],
                              String(describing: row.dtype) == agreement.request.profile.selectedRowDType else {
                            throw ProbeError("GLM final row differs from the agreed readout")
                        }
                        output = .logits(row)
                    }
                    try checked()
                    try afterEvaluation(output)
                    try checked()
                    result = output
                }
                schedule = nextSchedule
                // A kept prompt frontier is captured once its frame is committed.
                // Capture throws only on a broken invariant; it then fails the
                // request after the frame was published, like any later fault.
                if frame.phase == .prefill, let prefixCapture {
                    try prefixCapture.capture(at: frame.tokenOffset + frame.tokenCount, caches: cache.layers,
                        globalLayers: Array(model.plan.layers))
                    try checked()
                }
                return result!
            }
        } catch {
            isFailed = true
            throw error
        }
    }

    /// Poison the request after a transport/control failure, including an ACK
    /// lost after local commit. Keep all native state until the owner's fence.
    func invalidate() { isFailed = true }

    /// The outer request owner must first retire/fence its peer. This method
    /// joins local work before releasing the complete recurrent/attention cache.
    func close(check: () throws -> Void) throws {
        guard !inOperation else { throw ProbeError("GLM request cannot close inside a frame") }
        guard !isClosed else { return }
        try MLX.withError { error in
            Stream.gpu.synchronize()
            try error.check(); try check()
            Stream.cpu.synchronize(); try error.check(); try check()
            cache = nil; imageFeatures = nil; isClosed = true
        }
    }

    private func validate(_ boundary: QwenLayerStageBoundary,
                          frame: QwenLayerStageFrame, tokens: [Int]) throws {
        let descriptor = agreement.descriptor
        guard boundary.requestFingerprint == identity.requestFingerprint,
              boundary.sourceConfigurationSHA256 == identity.sourceConfigurationSHA256,
              boundary.artifactAggregateSHA256 == identity.artifactAggregateSHA256,
              boundary.storageCommitmentSHA256 == identity.storageCommitmentSHA256,
              boundary.planFingerprint == identity.planFingerprint,
              boundary.producerStageFingerprint == descriptor.stageFingerprints[0],
              boundary.frame == frame,
              boundary.tokenIDsSHA256 == QwenLayerStageBoundary.tokenHash(tokens),
              String(describing: boundary.array.dtype) == agreement.request.profile.activationDType else {
            throw ProbeError("GLM incoming boundary differs from its loaded request identity")
        }
        try boundary.validateOwnedArray(tokens: tokens.count,
            hidden: agreement.request.profile.hiddenSize, dtype: boundary.array.dtype, residualStreams: 4)
    }
}
