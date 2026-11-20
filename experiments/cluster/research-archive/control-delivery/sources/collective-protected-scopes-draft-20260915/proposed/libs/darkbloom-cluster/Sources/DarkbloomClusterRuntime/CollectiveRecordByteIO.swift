import DarkbloomClusterSecurity
import Foundation
import MLX

/// A private native endpoint can provide this capability; Collective itself
/// deliberately does not conform, preventing ciphertext facade recursion.
protocol CollectiveCiphertextEndpoint: AnyObject {
    var rank: Int { get }
    var size: Int { get }
    func sendCiphertextFrame(_ input: MLXArray, maximumBytes: Int, check: () throws -> Void) throws
    func receiveCiphertextFrame(byteCount: Int, check: () throws -> Void) throws -> MLXArray
}

/// Logical ciphertext frames. Requires the separately qualified native zero-tail
/// staging fix as well as the authenticated record path.
final class CollectiveRecordByteIO: ClusterRecordByteIO {
    private let endpoint: any CollectiveCiphertextEndpoint
    let localRank: Int
    let worldSize: Int
    let maximumFrameBytes: Int

    init(endpoint: any CollectiveCiphertextEndpoint, maximumFrameBytes: Int) throws {
        guard endpoint.size == 2, (0...1).contains(endpoint.rank),
              maximumFrameBytes > ClusterRecordTransferAccounting.framingBytes,
              maximumFrameBytes <= CollectivePointToPointShape.hardByteLimit else {
            throw ProbeError("Encrypted record byte IO requires bounded two-rank P2P")
        }
        self.endpoint = endpoint; localRank = endpoint.rank; worldSize = endpoint.size
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
                try endpoint.sendCiphertextFrame(array, maximumBytes: bytes.count, check: checked)
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
            let array = try endpoint.receiveCiphertextFrame(byteCount: byteCount, check: checked)
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
