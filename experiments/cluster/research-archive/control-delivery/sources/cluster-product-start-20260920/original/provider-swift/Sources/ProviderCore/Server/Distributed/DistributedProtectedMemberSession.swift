import Foundation
import MLXLMCommon

/// Closed adapter for an already-authorized, already-loaded member session.
/// It launches no processes and retains the same member loop through retirement.
/// No public initializer or CLI/HTTP route enables this experimental workload.
final class DistributedProtectedMemberSession: DistributedLocalServerSession, @unchecked Sendable {
    let model: DistributedInstalledModel
    let expectedIdentity: DistributedResidentIdentity
    let profile: DistributedResidentExecutionProfile
    let httpInstalledBinding: ClusterStatusBinding?
    private let backend: any ProtectedMemberSessionBackend
    private let retainMemberLoop: any Sendable
    private let validateInputs: @Sendable () throws -> Void
    private let lock = NSLock(), stopped = NativePairSessionCompletionSignal()
    private var phase: DistributedInstalledSessionStatus = .prepared
    private var teardown: Task<Void, Never>?
    private var interrupt: Task<Void, Never>?
    private var ownerJoined = false
    private var joined = false
    private var handler: (@Sendable () -> Void)?
    private var notified = false

    // This internal injection seam is also used by model-free lifecycle tests.
    // The product factory supplies verified metadata and NativePairRetainedSession.
    init(model: DistributedInstalledModel, identity: DistributedResidentIdentity,
         profile: DistributedResidentExecutionProfile, backend: any ProtectedMemberSessionBackend,
         retainMemberLoop: any Sendable, installedBinding: ClusterStatusBinding? = nil, validateInputs: @escaping @Sendable () throws -> Void) throws {
        guard backend.epoch == identity.membershipEpoch, let ready = backend.owner.readiness(),
              ready.identity == identity, ready.profileID == profile.id, ready.requestCapacityBytes > 0,
              backend.lifetime > DispatchTime.now().uptimeNanoseconds else {
            throw DistributedEngineError.unavailable
        }
        try validateInputs()
        self.model = model; expectedIdentity = identity; self.profile = profile
        httpInstalledBinding = installedBinding
        self.backend = backend; self.retainMemberLoop = retainMemberLoop; self.validateInputs = validateInputs
        backend.owner.setReadinessInvalidationHandler { [weak self] in self?.beginStop(drain: false) }
    }

    var status: DistributedInstalledSessionStatus { lock.withLock { phase } }
    var httpAdmissionAvailable: Bool { status == .ready && backend.canAdmit }
    var httpSessionInvalid: Bool { status == .quarantined || backend.invalid }
    var httpSessionExhausted: Bool { status == .ready && backend.exhausted }
    var httpCanRotate: Bool {
        let local = lock.withLock { phase == .released && joined }
        guard local, let value = backend.completion else { return false }
        return value.membershipEpoch == expectedIdentity.membershipEpoch && value.released
    }
    var lifetimeDeadlineUptimeNanoseconds: UInt64? { backend.lifetime }
    func validateModelInputs() throws { try validateInputs() }

    func start() async throws {
        try lock.withLock {
            guard phase == .prepared else { throw DistributedEngineError.unavailable }
            phase = .starting
        }
        do {
            try Task.checkCancellation(); try validateInputs(); try Task.checkCancellation()
            try lock.withLock {
                guard phase == .starting else { throw DistributedEngineError.shuttingDown }
            }
            guard let ready = backend.owner.readiness(), ready.identity == expectedIdentity,
                  ready.profileID == profile.id, backend.canAdmit,
                  backend.lifetime > DispatchTime.now().uptimeNanoseconds else { throw DistributedEngineError.unavailable }
            try lock.withLock {
                guard phase == .starting else { throw DistributedEngineError.shuttingDown }
                phase = .ready
            }
        } catch { beginStop(drain: false); throw error }
    }

    func readiness() -> DistributedResidentReadiness? {
        guard status == .ready || status == .draining else { return nil }
        guard let value = backend.owner.readiness(), value.identity == expectedIdentity else { return nil }
        return value
    }
    func setReadinessInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        let notify = lock.withLock { () -> Bool in
            self.handler = handler
            guard [.stopping, .quarantined, .released].contains(phase), !notified else { return false }
            notified = true; return true
        }
        if notify { DispatchQueue.global().async(execute: handler) }
    }
    func projectFirstToken(_ request: CBv2Request, admission: CBv2FirstTokenDeadlineAdmission) -> CBv2FirstTokenProjectedWork {
        backend.owner.projectFirstToken(request, admission: admission)
    }
    func reserve(_ request: CBv2Request, identity: DistributedResidentIdentity, profileID: String,
                 capacityLimit: Int) throws -> any DistributedResidentRequestLease {
        try requireAdmission(identity: identity, profileID: profileID)
        return try backend.owner.reserve(request, identity: identity, profileID: profileID, capacityLimit: capacityLimit)
    }
    func reserve(_ request: CBv2Request, identity: DistributedResidentIdentity, profileID: String,
                 capacityLimit: Int, deadlineContext: DistributedRequestDeadlineContext) throws -> any DistributedResidentRequestLease {
        try requireAdmission(identity: identity, profileID: profileID)
        return try backend.owner.reserve(request, identity: identity, profileID: profileID,
            capacityLimit: capacityLimit, deadlineContext: deadlineContext)
    }
    private func requireAdmission(identity: DistributedResidentIdentity, profileID: String) throws {
        guard identity == expectedIdentity, profileID == profile.id, httpAdmissionAvailable else {
            throw DistributedEngineError.unavailable
        }
    }

    func stop(until deadline: UInt64) async -> DistributedInstalledSessionStatus {
        beginStop(drain: false); return await wait(until: deadline)
    }
    func drain(until deadline: UInt64) async -> DistributedInstalledSessionStatus {
        beginStop(drain: true); return await wait(until: deadline)
    }
    func shutdown() async {
        let active = lock.withLock { teardown != nil }
        if !active { beginStop(drain: false) }
        _ = await stopped.wait()
    }
    private func wait(until deadline: UInt64) async -> DistributedInstalledSessionStatus {
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if lock.withLock({ joined }) { return status }
            do { try await Task.sleep(for: .milliseconds(5)) }
            catch { beginStop(drain: false); break }
        }
        lock.withLock { if phase != .released { phase = .quarantined } }
        return status
    }
    private func beginStop(drain: Bool) {
        // Close the original Pair's atomic reserve gate before scheduling any
        // asynchronous drain. A racing reservation is either retained or refused.
        backend.closeAdmissions()
        let callback = lock.withLock { () -> (@Sendable () -> Void)? in
            guard phase != .released else { return nil }
            if phase != .quarantined { phase = drain && interrupt == nil ? .draining : .stopping }
            if teardown == nil { teardown = Task { await self.finishStop(drain: drain) } }
            if !drain && interrupt == nil && !ownerJoined {
                // Interrupt a previously started graceful drain without waiting
                // on its active-request hold. The original Pair owns cancellation.
                interrupt = Task { self.backend.cancel(); await self.backend.owner.shutdown() }
            }
            guard !drain, !notified, let handler else { return nil }
            notified = true; return handler
        }
        if let callback { DispatchQueue.global().async(execute: callback) }
    }
    private func finishStop(drain: Bool) async {
        if drain { await backend.drain() } else { await backend.owner.shutdown() }
        // No new interrupt task may start after this join. This makes the later
        // interrupt snapshot stable before publishing reusable completion.
        lock.withLock { ownerJoined = true }
        let value = await backend.waitForCompletion()
        let interrupted = lock.withLock { interrupt }
        await interrupted?.value
        lock.withLock {
            joined = true
            phase = value.membershipEpoch == expectedIdentity.membershipEpoch && value.released ? .released : .quarantined
        }
        stopped.complete(value)
    }
}
