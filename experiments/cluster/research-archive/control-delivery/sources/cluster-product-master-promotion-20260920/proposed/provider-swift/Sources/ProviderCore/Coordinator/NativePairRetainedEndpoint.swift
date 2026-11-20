import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
import DarkbloomClusterRemote

/// A non-owning view of an already committed member's worker. It never launches
/// an owner. Missing authenticated cleanup keeps the completion unresolved.
final class NativePairRetainedEndpoint: ClusterWorkerEndpoint, @unchecked Sendable {
    let expectedIdentity: ClusterWorkerIdentity
    let expectedProfile: ClusterWorkerProfile
    let rank: Int
    let executionPlanSHA256: String
    let localLifetimeDeadlineUptimeNanoseconds: UInt64
    private let readyPolicy: ClusterOwnerProtectedReady
    private let sendBody: @Sendable (ClusterWorkerCommand, UUID?, UInt64) throws -> Void
    private let cancelBody: @Sendable () -> Void
    private let condition = NSCondition(), cleanup = DispatchGroup()
    private var events: [ClusterWorkerEventFrame] = []
    private var nextEvent: UInt64 = 0
    private var ready: ClusterWorkerReady?
    private var invalid = false, cleaned = false, notified = false
    private var handler: (@Sendable () -> Void)?
    init(identity: ClusterWorkerIdentity, profile: ClusterWorkerProfile, rank: Int, plan: String, lifetime: UInt64,
         readyPolicy: ClusterOwnerProtectedReady,
         send: @escaping @Sendable (ClusterWorkerCommand, UUID?, UInt64) throws -> Void,
         cancel: @escaping @Sendable () -> Void) {
        expectedIdentity=identity;expectedProfile=profile;self.rank=rank;executionPlanSHA256=plan
        localLifetimeDeadlineUptimeNanoseconds=lifetime;self.readyPolicy=readyPolicy;sendBody=send;cancelBody=cancel
        cleanup.enter()
    }
    var readiness: ClusterWorkerReady? { condition.lock(); defer { condition.unlock() }; return invalid || cleaned ? nil : ready }
    var nativeCleanupObserved: Bool { condition.lock(); defer { condition.unlock() }; return cleaned }
    func accept(_ frame: ClusterWorkerEventFrame) throws {
        condition.lock(); defer { condition.unlock() }
        guard !invalid, frame.membershipEpoch == expectedIdentity.membershipEpoch,
              frame.sequence == nextEvent, events.count < 32 else { throw NativePairMemberError.binding }
        if case .ready(let value) = frame.event {
            guard nextEvent == 0, frame.requestID == nil else { throw NativePairMemberError.binding }
            try readyPolicy.validate(value); ready=value
        } else { guard nextEvent > 0 else { throw NativePairMemberError.binding } }
        events.append(frame); nextEvent += 1; condition.broadcast()
    }
    func invalidate(cleanupObserved: Bool = false) {
        condition.lock(); invalid=true; ready=nil; events.removeAll(keepingCapacity:false)
        let complete = cleanupObserved && !cleaned
        if complete { cleaned=true }
        let notify = !notified ? handler : nil
        if notify != nil { notified=true }; condition.broadcast(); condition.unlock()
        if complete { cleanup.leave() }
        if let notify { DispatchQueue.global().async(execute: notify) }
    }
    /// Actual normal owner cleanup closes admission while allowing already
    /// validated terminal events to drain. It does not undo cancellation.
    func observeCleanup() {
        condition.lock()
        let complete = !cleaned
        cleaned=true; ready=nil; condition.broadcast(); condition.unlock()
        if complete { cleanup.leave() }
    }
    func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        condition.lock(); self.handler=handler; let notify=invalid && !notified
        if notify { notified=true }; condition.unlock()
        if notify { DispatchQueue.global().async(execute: handler) }
    }
    func sendWorkerCommand(_ command: ClusterWorkerCommand, requestID: UUID?, deadline: UInt64) throws {
        condition.lock(); let allowed = !invalid && !cleaned && ready != nil; condition.unlock()
        guard allowed, deadline <= localLifetimeDeadlineUptimeNanoseconds else { throw ClusterWorkerOwnerError.closed }
        if case .reserve(let value) = command { try NativePairWorkerPacket.requireExperiment(value) }
        try sendBody(command,requestID,deadline)
    }
    func receiveWorkerEvent(until deadline: UInt64, cancelled: () -> Bool) throws -> ClusterWorkerEventFrame {
        condition.lock(); defer { condition.unlock() }
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if cancelled() { throw ClusterWorkerOwnerError.cancelled }
            if invalid { throw ClusterWorkerOwnerError.closed }
            if !events.isEmpty { return events.removeFirst() }
            if cleaned { throw ClusterWorkerOwnerError.closed }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.02))
        }
        throw ClusterWorkerOwnerError.deadline
    }
    func requestNativeCleanup() { invalidate(); cancelBody() }
    func waitForNativeCleanup() { cleanup.wait() }
    func waitUntilNativeCleanup() async {
        await withCheckedContinuation { continuation in cleanup.notify(queue: .global()) { continuation.resume() } }
    }
}
