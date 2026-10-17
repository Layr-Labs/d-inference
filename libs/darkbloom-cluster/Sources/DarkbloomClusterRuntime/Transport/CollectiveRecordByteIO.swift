import DarkbloomClusterSecurity
import Foundation
import MLX

/// Logical ciphertext frames only, on the Collective's raw completed P2P,
/// which still owns all native fences. Once a data plane is keyed, every
/// transfer between the ranks is such a frame, so a native buffer tail can
/// only ever hold earlier ciphertext or the public hellos.
public final class CollectiveRecordByteIO: ClusterRecordByteIO {
    private unowned let collective: Collective
    public let localRank: Int
    public let worldSize: Int
    public let maximumFrameBytes: Int
    /// Qualification only: flips one ciphertext byte of the n-th sent record of a kind.
    private let tamper: CollectiveRecordTamper?
    private var tamperSeen = 0
    private(set) var tampered = false

    init(collective: Collective, maximumFrameBytes: Int, tamper: CollectiveRecordTamper? = nil) throws {
        guard collective.size == 2, (0...1).contains(collective.rank),
              maximumFrameBytes > ClusterRecordTransferAccounting.framingBytes,
              maximumFrameBytes <= CollectivePointToPointShape.hardByteLimit else {
            throw ProbeError("Encrypted record byte IO requires bounded two-rank P2P")
        }
        self.collective = collective; localRank = collective.rank; worldSize = collective.size
        self.maximumFrameBytes = maximumFrameBytes; self.tamper = tamper
    }

    /// The record header's kind byte; exact records are one frame each.
    private func tampering(_ bytes: Data) -> Data {
        guard let tamper, !tampered, bytes.count > 24,
              bytes[bytes.startIndex + 7] == tamper.type.rawValue else { return bytes }
        tamperSeen += 1
        guard tamperSeen == tamper.ordinal else { return bytes }
        tampered = true
        var copy = bytes
        copy[copy.startIndex + 24] ^= 0x01
        log("darkbloom-data-plane-tamper-v1 rank=\(localRank) kind=\(tamper.type) ordinal=\(tamper.ordinal)"
            + " (qualification fault: one ciphertext byte flipped after sealing)")
        return copy
    }

    public func sendCompleted(_ bytes: Data, check: () throws -> Void) throws {
        guard !bytes.isEmpty, bytes.count <= maximumFrameBytes else {
            throw ProbeError("Encrypted native send frame exceeds its admitted ceiling")
        }
        try MLX.withError { error in
            func checked() throws { try error.check(); try check(); try error.check() }
            try checked()
            // Direct Data initializer avoids a separate Array<UInt8> staging copy.
            // It still copies into native storage; no zero-copy claim is made.
            let frame = tampering(bytes)
            try withExtendedLifetime(frame) {
                let array = MLXArray(frame, [frame.count], type: UInt8.self)
                try checked()
                _ = try collective.rawSendCompleted(array, to: 1 - localRank,
                    maximumBytes: frame.count, check: checked)
                try checked()
            }
        }
    }

    public func receiveCompleted(byteCount: Int, check: () throws -> Void) throws -> Data {
        guard byteCount > 0, byteCount <= maximumFrameBytes else {
            throw ProbeError("Encrypted native receive frame exceeds its admitted ceiling")
        }
        return try MLX.withError { error in
            func checked() throws { try error.check(); try check(); try error.check() }
            try checked()
            let array = try collective.rawReceiveCompleted(shape: [byteCount], dtype: .uint8,
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
    public func maximumNativeFrameAllocation(for length: ClusterRecordTransferLength) throws -> Int {
        let accounting = try ClusterRecordTransferAccounting(length: length,
            maximumTransportFrameBytes: maximumFrameBytes)
        return try accounting.maximumFrameByteCounts.map {
            try Memory.allocationFootprintUpperBound(byteCount: $0)
        }.max()!
    }
}
