import Foundation

/// Bounded serial publication off Pair/Request locks. Invalidation interrupts
/// queued work; an already-entered synchronous signer remains non-preemptible.
final class NativePairRequestWriter: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending: [(NativePairWorkerPacket,UInt64)] = []
    private var running=false, invalid=false
    private let send: @Sendable (NativePairWorkerPacket,UInt64) throws -> Void
    private let failed: @Sendable () -> Void
    init(send: @escaping @Sendable (NativePairWorkerPacket,UInt64) throws -> Void, failed: @escaping @Sendable () -> Void) {
        self.send=send;self.failed=failed
    }
    func submit(_ packet: NativePairWorkerPacket, until: UInt64) throws {
        condition.lock()
        guard !invalid, pending.count < 16, DispatchTime.now().uptimeNanoseconds < until else {
            condition.unlock();throw NativePairMemberError.queue
        }
        pending.append((packet,until)); let launch = !running; running=true;condition.unlock()
        if launch { DispatchQueue(label:"darkbloom.native-member.requests.write").async { self.drain() } }
    }
    private func drain() {
        while true {
            condition.lock()
            if invalid || pending.isEmpty {running=false;condition.broadcast();condition.unlock();return}
            let item=pending.removeFirst();condition.unlock()
            do {try send(item.0,item.1)} catch {invalidate();failed()}
        }
    }
    func invalidate() {condition.lock();invalid=true;pending=[];condition.broadcast();condition.unlock()}
    func join(until deadline: UInt64) -> Bool {
        condition.lock();defer{condition.unlock()}
        while running && DispatchTime.now().uptimeNanoseconds < deadline {_ = condition.wait(until:Date(timeIntervalSinceNow:0.02))}
        return !running && pending.isEmpty
    }
}
