import CryptoKit
import DarkbloomClusterSecurity
import Foundation
import MLX

/// Model-independent native adapter. No constructor establishes peer authority:
/// supplied keys/transcripts need separate coordinator membership and fresh-key
/// establishment. This source candidate is not installed or enabled by config.
final class CollectiveAuthenticatedRecords {
    private let bytes: CollectiveRecordByteIO
    private let records: ClusterAuthenticatedRecordTransport

    init(collective: Collective, sessionKey: SymmetricKey, binding: ClusterRecordBinding,
         limits: ClusterRecordLimits, maximumFrameBytes: Int) throws {
        let io = try CollectiveRecordByteIO(collective: collective, maximumFrameBytes: maximumFrameBytes)
        self.bytes = io
        self.records = try .init(sessionKey: sessionKey, binding: binding, limits: limits, io: io)
    }

    var status: ClusterRecordTransportStatus { records.status }
    func invalidate() { records.invalidate() }
    func maximumNativeFrameAllocation(for length: ClusterRecordTransferLength) throws -> Int {
        try bytes.maximumNativeFrameAllocation(for: length)
    }
    func send(_ data: Data, expecting expected: ClusterRecordTransferExpectation,
              check: () throws -> Void) throws {
        try records.send(data, expecting: expected, check: check)
    }
    func receive(expecting expected: ClusterRecordTransferExpectation,
                 check: () throws -> Void) throws -> Data {
        try records.receive(expecting: expected, check: check)
    }

    /// Keeps native dtype bytes unchanged. No payload is placed in AAD; only
    /// independently expected shape/dtype and the caller's metadata digest.
    func sendArray(_ input: MLXArray, context: ClusterRecordContext,
                   expectedShape: [Int], expectedDType: DType,
                   check: () throws -> Void) throws {
        do {
            func checked() throws {
                try check()
                guard records.status.active else { throw ClusterRecordTransferError.inactive }
            }
            let (geometry, expectation) = try arrayExpectation(context: context,
                shape: expectedShape, dtype: expectedDType)
            try geometry.validateMetadata(input)
            try checked()
            let plaintext = try CollectivePointToPoint.copyCompletedBytes(input,
                maximumBytes: geometry.byteCount, check: checked)
            try records.send(plaintext, expecting: expectation, check: checked)
        } catch { records.invalidate(); throw error }
    }

    /// Authentication and post-open cancellation check precede the native array
    /// constructor. Caller retains its ordinary semantic/frontier/ownership check.
    func receiveArray(context: ClusterRecordContext, expectedShape: [Int], expectedDType: DType,
                      check: () throws -> Void) throws -> MLXArray {
        do {
            let (geometry, expectation) = try arrayExpectation(context: context,
                shape: expectedShape, dtype: expectedDType)
            let plaintext = try records.receive(expecting: expectation, check: check)
            try check()
            guard records.status.active else { throw ClusterRecordTransferError.inactive }
            let array = try CollectivePointToPoint.materializeCompletedBytes(plaintext,
                shape: geometry.shape, dtype: geometry.dtype, maximumBytes: geometry.byteCount,
                check: {
                    try check()
                    guard self.records.status.active else { throw ClusterRecordTransferError.inactive }
                })
            try check()
            return array
        } catch { records.invalidate(); throw error }
    }

    private func arrayExpectation(context: ClusterRecordContext, shape: [Int], dtype: DType)
        throws -> (CollectivePointToPointShape, ClusterRecordTransferExpectation) {
        let geometry = try CollectivePointToPointShape(shape: shape, dtype: dtype,
            maximumBytes: records.maximumPlaintextBytes)
        let type: UInt8
        switch dtype {
        case .uint8: type = 1
        case .uint32: type = 2
        case .int32: type = 3
        case .float16: type = 4
        case .bfloat16: type = 5
        case .float32: type = 6
        default: throw ProbeError("Encrypted residual has unsupported native dtype")
        }
        var metadata = Data("darkbloom/rdma-record/native-array-layout/v1\0".utf8)
        metadata.append(context.expectationSHA256); metadata.append(type); metadata.append(UInt8(shape.count))
        for dimension in shape {
            var value = UInt32(dimension).bigEndian
            withUnsafeBytes(of: &value) { metadata.append(contentsOf: $0) }
        }
        let bound = try ClusterRecordContext(requestID: context.requestID, type: context.type,
            expectationSHA256: Data(SHA256.hash(data: metadata)))
        return (geometry, try .init(context: bound, length: .exact(geometry.byteCount)))
    }
}
