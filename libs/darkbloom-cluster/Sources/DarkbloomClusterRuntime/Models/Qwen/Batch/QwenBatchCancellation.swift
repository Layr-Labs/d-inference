import Foundation

/// The native cancellation seam: publication is allowed only after every
/// session closed and its captured prefix references have been discarded.
protocol QwenBatchCancellableSession: AnyObject {
    var isClosed: Bool { get }
    func cancel() throws
    func discardCapturedPrefix()
}

extension QwenLayerStageSession: QwenBatchCancellableSession {}

enum QwenBatchCancellation {
    static func requested(ownerCancelled: Bool, deadline: UInt64, now: UInt64) -> Bool {
        ownerCancelled || now >= deadline
    }

    /// The authenticated reply's bits refer to the same header's occupied
    /// lanes. Empty/leaving slots cannot be used to cancel a later occupant.
    static func peerRequests(mask: Int, slots: [QwenBatchWire.Slot]) throws -> Set<UUID> {
        guard (1...QwenBatchWire.maximumLanes).contains(slots.count),
              mask >= 0, mask < (1 << slots.count) else {
            throw ProbeError("Batch cancellation mask is outside the agreed lanes")
        }
        var result = Set<UUID>()
        for (slot, value) in slots.enumerated() where mask & (1 << slot) != 0 {
            guard value.state == .joining || value.state == .active, let id = value.requestID,
                  result.insert(id).inserted else {
                throw ProbeError("Batch cancellation reply names no unique running lane")
            }
        }
        return result
    }

    /// Try every session even if an earlier native retirement fails. Failure
    /// keeps the charge held and publishes no retirement: the pair must fence.
    static func retire(sessions: [any QwenBatchCancellableSession],
                       release: () -> Void, publish: () throws -> Void) throws {
        var failure: Error?
        for session in sessions {
            do {
                try session.cancel()
                guard session.isClosed else { throw ProbeError("Batch cancelled lane retained native request state") }
            } catch { if failure == nil { failure = error } }
            session.discardCapturedPrefix()
        }
        if let failure { throw failure }
        release()
        try publish()
    }
}
