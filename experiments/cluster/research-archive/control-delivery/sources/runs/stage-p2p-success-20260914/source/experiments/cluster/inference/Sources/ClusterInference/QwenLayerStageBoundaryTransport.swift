import Foundation
import MLX

/// One residual in flight, synchronous MLX ownership, no retry. A thrown error
/// retires this transport; its owner must retire both stage processes and states.
/// Backend calls additionally require the native alarm and parent deadline.
final class QwenLayerStageBoundaryTransport {
    private let collective: Collective
    private(set) var isFailed = false

    init(collective: Collective) { self.collective = collective }

    func send(_ boundary: QwenLayerStageBoundary,
              expected: QwenLayerStageBoundaryWireExpectation,
              check: () throws -> Void) throws -> String {
        try operation {
            guard collective.rank == 0 else { throw ProbeError("Only stage zero sends residuals") }
            let source = try QwenLayerStageWireSourceIdentity(
                sourceConfigurationSHA256: boundary.sourceConfigurationSHA256,
                artifactAggregateSHA256: boundary.artifactAggregateSHA256,
                storageCommitmentSHA256: boundary.storageCommitmentSHA256,
                planFingerprint: boundary.planFingerprint,
                producerStageFingerprint: boundary.producerStageFingerprint)
            let header = try QwenLayerStageBoundaryWireHeader(
                requestFingerprint: boundary.requestFingerprint, sourceIdentity: source,
                frame: boundary.frame, tokenIDsSHA256: boundary.tokenIDsSHA256,
                payloadSHA256: boundary.payloadSHA256, shape: boundary.array.shape,
                dtype: String(describing: boundary.array.dtype), byteCount: boundary.array.nbytes)
            try header.validate(expected: expected)
            try header.validatePayload(boundary.array.asData().data)
            try check()
            let encoded = try header.encoded()
            _ = try collective.sendCompleted(MLXArray([UInt32(encoded.count)]), to: 1,
                maximumBytes: 4, check: check)
            _ = try collective.sendCompleted(MLXArray(Array(encoded)), to: 1,
                maximumBytes: QwenLayerStageBoundaryWireHeader.maximumEncodedBytes, check: check)
            try receiveAcknowledgement(header: encoded, phase: .ready, check: check)
            _ = try collective.sendCompleted(boundary.array, to: 1,
                maximumBytes: expected.byteCount, check: check)
            try receiveAcknowledgement(header: encoded, phase: .consumed, check: check)
            return sha256(encoded)
        }
    }

    /// The callback must finish evaluating and committing stage one's state
    /// before returning. If validation/consumption fails no consumed ACK is sent.
    func receive<T>(expected: QwenLayerStageBoundaryWireExpectation,
                    consume: (QwenLayerStageBoundary) throws -> T,
                    check: () throws -> Void) throws -> (value: T, headerSHA256: String) {
        try operation {
            guard collective.rank == 1 else { throw ProbeError("Only stage one receives residuals") }
            let length = try collective.receiveCompleted(shape: [1], dtype: .uint32,
                from: 0, maximumBytes: 4, check: check).item(UInt32.self)
            guard length > 0, length <= QwenLayerStageBoundaryWireHeader.maximumEncodedBytes else {
                throw ProbeError("Stage wire header length exceeds its local bound")
            }
            let encoded = try collective.receiveCompleted(shape: [Int(length)], dtype: .uint8,
                from: 0, maximumBytes: QwenLayerStageBoundaryWireHeader.maximumEncodedBytes,
                check: check).asData().data
            try check()
            // All allocation metadata below comes from this trusted expectation.
            let header = try QwenLayerStageBoundaryWireHeader.decode(encoded, expected: expected)
            try sendAcknowledgement(header: encoded, phase: .ready, check: check)
            let dtype: DType
            switch expected.dtype {
            case "float16": dtype = .float16
            case "bfloat16": dtype = .bfloat16
            case "float32": dtype = .float32
            default: throw ProbeError("Stage wire native dtype is unsupported")
            }
            let array = try collective.receiveCompleted(shape: expected.shape, dtype: dtype,
                from: 0, maximumBytes: expected.byteCount, check: check)
            let boundary = QwenLayerStageBoundary(requestFingerprint: header.requestFingerprint,
                sourceConfigurationSHA256: header.sourceConfigurationSHA256,
                artifactAggregateSHA256: header.artifactAggregateSHA256,
                storageCommitmentSHA256: header.storageCommitmentSHA256,
                planFingerprint: header.planFingerprint, producerStageFingerprint: header.producerStageFingerprint,
                frame: header.frame, tokenIDsSHA256: header.tokenIDsSHA256,
                payloadSHA256: header.payloadSHA256, array: array)
            try boundary.validateOwnedArray(tokens: expected.shape[1], hidden: expected.shape[2], dtype: dtype)
            try check()
            let result = try consume(boundary)
            try check()
            try sendAcknowledgement(header: encoded, phase: .consumed, check: check)
            return (result, sha256(encoded))
        }
    }

    private func sendAcknowledgement(header: Data, phase: QwenLayerStageWireAcknowledgement.Phase,
                                     check: () throws -> Void) throws {
        let values = QwenLayerStageWireAcknowledgement.values(header: header, phase: phase)
        _ = try collective.sendCompleted(MLXArray(values), to: 0,
            maximumBytes: QwenLayerStageWireAcknowledgement.byteCount, check: check)
    }

    private func receiveAcknowledgement(header: Data, phase: QwenLayerStageWireAcknowledgement.Phase,
                                        check: () throws -> Void) throws {
        let values = try collective.receiveCompleted(
            shape: [QwenLayerStageWireAcknowledgement.elements], dtype: .int32, from: 1,
            maximumBytes: QwenLayerStageWireAcknowledgement.byteCount, check: check).asArray(Int32.self)
        try check()
        try QwenLayerStageWireAcknowledgement.validate(values, header: header, phase: phase)
    }

    private func operation<T>(_ body: () throws -> T) throws -> T {
        guard !isFailed else { throw ProbeError("Stage wire transport is retired") }
        do { return try body() } catch { isFailed = true; throw error }
    }
}
