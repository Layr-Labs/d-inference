import Foundation
import MLX
import MLXLMCommon

extension Gemma4BenchmarkWire {
    func sendProbe(_ array: MLXArray, phase: CBv2NativeKVTypeProbe.Phase,
                   check: () throws -> Void) throws {
        let sequence = phase == .prefill ? 0 : 1, count = try Gemma4BenchmarkFrames.probeCount(phase == .prefill ? 0 : 1)
        try sendPayload(array, value: .init(event: "probe", sequence: sequence, frontier: sequence == 0 ? 2 : 3,
            count: count, tokenIDsSHA256: qwenGenerationTokenHash(Array(repeating: 0, count: count)),
            dtype: input.job.residualDType), receipt: "probe-buffer-received", check: check)
    }

    func receiveProbe(phase: CBv2NativeKVTypeProbe.Phase, count: Int,
                      check: () throws -> Void) throws -> MLXArray {
        let sequence = phase == .prefill ? 0 : 1
        guard count == (try Gemma4BenchmarkFrames.probeCount(sequence)) else { throw ProbeError("Gemma actual probe count differs") }
        return try receivePayload(value: .init(event: "probe", sequence: sequence, frontier: sequence == 0 ? 2 : 3,
            count: count, tokenIDsSHA256: qwenGenerationTokenHash(Array(repeating: 0, count: count)),
            dtype: input.job.residualDType), receipt: "probe-buffer-received", check: check).0
    }

    private func ownedFrame(_ boundary: Gemma4ForwardBoundary, check: () throws -> Void) throws -> Gemma4ForwardBoundary {
        let frame = try Gemma4BenchmarkFrames.frame(boundary.frame.sequence, request: input.request)
        guard boundary.frame == frame, boundary.requestSHA256 == input.request.fingerprint,
              boundary.artifactSHA256 == Gemma4ArtifactMetadata.artifactAggregateSHA256,
              boundary.planSHA256 == input.plan.fingerprint, boundary.mappingSHA256 == input.plan.conservation.fingerprint,
              boundary.producerStageSHA256 == input.plan.stages[0].fingerprint else {
            throw ProbeError("Gemma produced boundary has a different request/Plan/frame")
        }
        let owned = try boundary.ownedCopy(check: check)
        try owned.requireOwned(tokens: frame.tokenCount, hidden: 2816, dtype: input.job.dtype)
        return owned
    }

    func sendFrame(_ boundary: Gemma4ForwardBoundary, check: () throws -> Void) throws {
        let owned = try ownedFrame(boundary, check: check)
        let frame = owned.frame
        try sendPayload(owned.array, value: .init(event: "frame", sequence: frame.sequence,
            frontier: frame.tokenOffset + frame.tokenCount, count: frame.tokenCount,
            tokenIDsSHA256: owned.tokenIDsSHA256, payloadSHA256: owned.payloadSHA256,
            dtype: input.job.residualDType), receipt: "frame-consumed", check: check)
    }

    /// Completed-send credit only. The returned ticket is CPU metadata; the
    /// original and transport copy can retire before preparing one next chunk.
    func sendFrameUntilSent(_ boundary: Gemma4ForwardBoundary, check: () throws -> Void) throws -> SentFrameTicket {
        guard input.job.prefill == .oneChunkLookahead, boundary.frame.phase == .prefill else {
            throw ProbeError("Gemma deferred consumption is prefill-only and explicitly selected")
        }
        let owned = try ownedFrame(boundary, check: check)
        let frame = owned.frame
        let value = try sendPayload(owned.array, value: .init(event: "frame", sequence: frame.sequence,
            frontier: frame.tokenOffset + frame.tokenCount, count: frame.tokenCount,
            tokenIDsSHA256: owned.tokenIDsSHA256, payloadSHA256: owned.payloadSHA256,
            dtype: input.job.residualDType), receipt: nil, check: check)
        return .init(value: value)
    }

    func receiveFrame(_ frame: QwenLayerStageFrame, tokens: [Int],
                      check: () throws -> Void) throws -> Gemma4ForwardBoundary {
        guard frame == (try Gemma4BenchmarkFrames.frame(frame.sequence, request: input.request)), tokens.count == frame.tokenCount else {
            throw ProbeError("Gemma incoming request frame differs from local geometry")
        }
        let (array, value) = try receivePayload(value: .init(event: "frame", sequence: frame.sequence,
            frontier: frame.tokenOffset + frame.tokenCount, count: frame.tokenCount,
            tokenIDsSHA256: qwenGenerationTokenHash(tokens), dtype: input.job.residualDType), receipt: nil, check: check)
        guard let payload = value.payloadSHA256 else { throw ProbeError("Gemma payload digest is missing") }
        return .init(requestSHA256: input.request.fingerprint, artifactSHA256: Gemma4ArtifactMetadata.artifactAggregateSHA256,
            planSHA256: input.plan.fingerprint, mappingSHA256: input.plan.conservation.fingerprint,
            producerStageSHA256: input.plan.stages[0].fingerprint, frame: frame,
            tokenIDsSHA256: qwenGenerationTokenHash(tokens), array: array, payloadSHA256: payload)
    }

    @discardableResult
    private func sendPayload(_ array: MLXArray, value: Gemma4BenchmarkWireValue, receipt: String?,
                             check: () throws -> Void) throws -> Gemma4BenchmarkWireValue {
        try operation {
            try requireNoPending(); try check()
            guard rank == 0, array.shape == [1, value.count, 2816], array.dtype == input.job.dtype else {
                throw ProbeError("Gemma producer native residual shape/dtype differs")
            }
            let bytes = value.count * 2816 * input.job.dtype.size
            // The real probe/session evaluated this tensor before publication.
            let copied = array.asData(access: .copy).data; try check()
            guard copied.count == bytes else { throw ProbeError("Gemma residual byte count differs") }
            let hash = sha256(copied)
            guard value.payloadSHA256 == nil || value.payloadSHA256 == hash else { throw ProbeError("Gemma source residual digest changed") }
            var header = value; header.payloadSHA256 = hash
            try send(header, check: check)
            let ready = changedEvent(header, "payload-ready")
            try require(ready, check: check)
            _ = try guardMetrics.measure(.wireSendCompleted) { try group.sendCompleted(array, to: 1, maximumBytes: bytes, check: check) }
            if let receipt { try require(changedEvent(header, receipt), check: check) }
            else { try retainPending(header) }
            return header
        }
    }

    private func receivePayload(value: Gemma4BenchmarkWireValue, receipt: String?,
                                check: () throws -> Void) throws -> (MLXArray, Gemma4BenchmarkWireValue) {
        try operation {
            try requireNoPending(); try check()
            guard rank == 1 else { throw ProbeError("Only Gemma final stage receives residuals") }
            let actual = try receive(check: check)
            var expected = value; expected.payloadSHA256 = actual.payloadSHA256
            guard actual == expected, let payload = actual.payloadSHA256, qwenStageWireIsSHA256(payload) else {
                throw ProbeError("Gemma residual header differs from the exact local operation")
            }
            let bytes = value.count * 2816 * input.job.dtype.size
            try send(changedEvent(actual, "payload-ready"), check: check)
            let array = try guardMetrics.measure(.wireReceiveCompleted) {
                try group.receiveCompleted(shape: [1, value.count, 2816], dtype: input.job.dtype,
                    from: 0, maximumBytes: bytes, check: check)
            }
            guard sha256(array.asData(access: .copy).data) == payload else { throw ProbeError("Gemma received residual checksum differs") }
            try check()
            if let receipt { try send(changedEvent(actual, receipt), check: check) }
            else { try retainPending(actual) }
            return (array, actual)
        }
    }

    private func changedEvent(_ value: Gemma4BenchmarkWireValue, _ event: String) -> Gemma4BenchmarkWireValue {
        .init(event: event, sequence: value.sequence, frontier: value.frontier, count: value.count,
            tokenIDsSHA256: value.tokenIDsSHA256, payloadSHA256: value.payloadSHA256,
            tokenID: value.tokenID, dtype: value.dtype)
    }
}
