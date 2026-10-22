import DarkbloomClusterSecurity
import Foundation
import MLX

/// Lab-only adapter around one existing raw owner. It cannot construct a
/// protected product Collective, approve a runtime or issue a native grant.
final class LabCiphertextEndpoint: CollectiveCiphertextEndpoint {
    let group: Collective
    var rank: Int { group.rank }; var size: Int { group.size }
    init(_ group: Collective) { self.group = group }
    func sendCiphertextFrame(_ input: MLXArray, maximumBytes: Int, check: () throws -> Void) throws {
        _ = try group.sendCompleted(input, to: 1 - rank, maximumBytes: maximumBytes, check: check)
    }
    func receiveCiphertextFrame(byteCount: Int, check: () throws -> Void) throws -> MLXArray {
        try group.receiveCompleted(shape: [byteCount], dtype: .uint8, from: 1 - rank, maximumBytes: byteCount, check: check)
    }
}

struct LabFrameObservation: Codable {
    let bytes: Int, sha256: String, nanoseconds: UInt64
}
final class LabTimedRecordIO: ClusterRecordByteIO {
    let io: CollectiveRecordByteIO
    var localRank: Int { io.localRank }; var worldSize: Int { io.worldSize }; var maximumFrameBytes: Int { io.maximumFrameBytes }
    private var sent: (Data, UInt64)?, received: (Data, UInt64)?
    init(_ io: CollectiveRecordByteIO) { self.io = io }
    func sendCompleted(_ bytes: Data, check: () throws -> Void) throws {
        guard sent == nil else { throw ProbeError("Lab frame observation not retired") }
        let start = DispatchTime.now().uptimeNanoseconds
        try io.sendCompleted(bytes, check: check)
        sent = (bytes, DispatchTime.now().uptimeNanoseconds - start)
    }
    func receiveCompleted(byteCount: Int, check: () throws -> Void) throws -> Data {
        guard received == nil else { throw ProbeError("Lab frame observation not retired") }
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try io.receiveCompleted(byteCount: byteCount, check: check)
        received = (value, DispatchTime.now().uptimeNanoseconds - start); return value
    }
    /// Digests and retention cleanup are outside the measured outer interval.
    func take() throws -> (LabFrameObservation, LabFrameObservation) {
        guard let sent, let received else { throw ProbeError("Lab requires exactly one frame per direction") }
        defer { self.sent = nil; self.received = nil }
        return (.init(bytes: sent.0.count, sha256: sha256(sent.0), nanoseconds: sent.1),
                .init(bytes: received.0.count, sha256: sha256(received.0), nanoseconds: received.1))
    }
    func discard() { sent = nil; received = nil }
}
