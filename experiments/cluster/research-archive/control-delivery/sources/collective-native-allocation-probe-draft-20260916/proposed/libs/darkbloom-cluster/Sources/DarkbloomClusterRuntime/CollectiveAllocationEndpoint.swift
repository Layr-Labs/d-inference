#if COLLECTIVE_RECORD_ALLOCATION_CHECK
import Foundation
import MLX

final class CollectiveAllocationWeakArray {
    weak var value: MLXArray?
    init(_ value: MLXArray) { self.value = value }
}

/// Only ciphertext delivery is in memory. Real native byte export/import and
/// codec/adapter paths remain unchanged; this is not a simulated RDMA result.
final class CollectiveAllocationMailbox {
    var frame: Data?
    var lengths: [Int] = []
    var nativeReceiveCompleted = false
    var weakArrays: [CollectiveAllocationWeakArray] = []
    var failure: CollectiveAllocationCase.Failure
    init(_ failure: CollectiveAllocationCase.Failure) { self.failure = failure }
    func track(_ array: MLXArray) throws {
        guard weakArrays.count < 256 else { throw ProbeError("Allocation fixture array inventory cap") }
        weakArrays.append(.init(array))
    }
}

final class CollectiveAllocationEndpoint: CollectiveCiphertextEndpoint {
    let rank: Int
    let size = 2
    let mailbox: CollectiveAllocationMailbox
    init(rank: Int, mailbox: CollectiveAllocationMailbox) { self.rank = rank; self.mailbox = mailbox }
    func sendCiphertextFrame(_ input: MLXArray, maximumBytes: Int, check: () throws -> Void) throws {
        try check()
        guard rank == 0, mailbox.frame == nil, mailbox.lengths.count < 64 else {
            throw ProbeError("Allocation fixture has overlapping or excess frames")
        }
        try mailbox.track(input)
        var frame = try CollectivePointToPoint.copyCompletedBytes(input, maximumBytes: maximumBytes, check: check)
        guard frame.count > 40 else { throw ProbeError("Allocation fixture frame is truncated") }
        if mailbox.failure == .ciphertext { frame[24] ^= 1 }
        if mailbox.failure == .tag { frame[frame.count - 1] ^= 1 }
        mailbox.lengths.append(frame.count); mailbox.frame = frame
        try check()
    }
    func receiveCiphertextFrame(byteCount: Int, check: () throws -> Void) throws -> MLXArray {
        try check()
        guard rank == 1, let frame = mailbox.frame, frame.count == byteCount else {
            throw ProbeError("Allocation fixture lacks an exact ciphertext frame")
        }
        mailbox.frame = nil
        let array = try CollectivePointToPoint.materializeCompletedBytes(frame, shape: [byteCount], dtype: .uint8,
            maximumBytes: byteCount, check: check)
        try mailbox.track(array)
        mailbox.nativeReceiveCompleted = true
        try check(); return array
    }
}
#endif
