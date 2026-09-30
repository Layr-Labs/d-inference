/// Request work may be queued before a backend slot starts decoding. The
/// daemon's local diagnosis must treat that memory snapshot as temporary.
enum DaemonWorkPosture {
    static func hasPendingRequest(inflight: Bool, capacity: BackendCapacity?) -> Bool {
        inflight || capacity?.slots.contains { $0.numWaiting > 0 } == true
    }
}
