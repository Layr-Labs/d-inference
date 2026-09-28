import DarkbloomClusterSecurity
import Foundation
import MLX

/// Logical ciphertext frames only. Existing completed P2P still owns all native
/// fences. The current JACCL full-buffer tail needs its separate native fix
/// before this logical adapter can qualify confidential RDMA wire bytes.
final class CollectiveRecordByteIO: ClusterRecordByteIO {
    private let collective: Collective
    let localRank: Int
    let worldSize: Int
    let maximumFrameBytes: Int

    init(collective: Collective, maximumFrameBytes: Int) throws {
        guard collective.size == 2, (0...1).contains(collective.rank),
              maximumFrameBytes > ClusterRecordTransferAccounting.framingBytes,
              maximumFrameBytes <= CollectivePointToPointShape.hardByteLimit else {
            throw ProbeError("Encrypted record byte IO requires bounded two-rank P2P")
        }
        self.collective = collective; localRank = collective.rank; worldSize = collective.size
        self.maximumFrameBytes = maximumFrameBytes
    }

    func sendCompleted(_ bytes: Data, check: () throws -> Void) throws {
        guard !bytes.isEmpty, bytes.count <= maximumFrameBytes else {
            throw ProbeError("Encrypted native send frame exceeds its admitted ceiling")
        }
        try MLX.withError { error in
            func checked() throws { try error.check(); try check(); try error.check() }
            try checked()
            // Direct Data initializer avoids a separate Array<UInt8> staging copy.
            // It still copies into native storage; no zero-copy claim is made.
            try withExtendedLifetime(bytes) {
                let array = MLXArray(bytes, [bytes.count], type: UInt8.self)
                try checked()
                _ = try collective.sendCompleted(array, to: 1 - localRank,
                    maximumBytes: bytes.count, check: checked)
                try checked()
            }
        }
    }

    func receiveCompleted(byteCount: Int, check: () throws -> Void) throws -> Data {
        guard byteCount > 0, byteCount <= maximumFrameBytes else {
            throw ProbeError("Encrypted native receive frame exceeds its admitted ceiling")
        }
        return try MLX.withError { error in
            func checked() throws { try error.check(); try check(); try error.check() }
            try checked()
            let array = try collective.receiveCompleted(shape: [byteCount], dtype: .uint8,
                from: 1 - localRank, maximumBytes: byteCount, check: checked)
            let copied = array.asData(access: .copy)
            try checked()
            guard copied.shape == [byteCount], copied.dType == .uint8, copied.data.count == byteCount else {
                throw ProbeError("Encrypted native frame copy changed layout")
            }
            return copied.data
        }
    }

    /// Native frame allocation bound only. Caller must additionally charge host
    /// plaintext/record/copy allocations, crypto workspace and model state.
    func maximumNativeFrameAllocation(for length: ClusterRecordTransferLength) throws -> Int {
        let accounting = try ClusterRecordTransferAccounting(length: length,
            maximumTransportFrameBytes: maximumFrameBytes)
        return try accounting.maximumFrameByteCounts.map {
            try Memory.allocationFootprintUpperBound(byteCount: $0)
        }.max()!
    }
}
