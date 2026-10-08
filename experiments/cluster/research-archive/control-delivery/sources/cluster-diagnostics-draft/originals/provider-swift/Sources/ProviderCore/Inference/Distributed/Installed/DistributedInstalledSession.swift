import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
import DarkbloomClusterRemote

public enum DistributedInstalledSessionStatus: String, Sendable {
    case prepared, starting, ready, draining, stopping, quarantined, released
}

/// One start attempt and its retained cleanup obligation. Missing peer proof is
/// quarantine, never an empty slot or authority to start another cohort.
public final class DistributedInstalledSession: @unchecked Sendable {
    public let configuration: ClusterConfiguration
    public let capability: ClusterRuntimeCapability
    public let expectedIdentity: DistributedResidentIdentity
    public let profile: DistributedResidentExecutionProfile
    public let model: DistributedInstalledModel
    private let prepared: DistributedInstalledPreparation
    private let wireIdentity: ClusterWorkerIdentity
    typealias EndpointFactory = @Sendable (DistributedInstalledPlan, ClusterWorkerIdentity, Int, UInt64, ClusterOwnerBootstrapRelay) throws -> ClusterRemoteWorkerEndpoint
    private let endpointFactory: EndpointFactory
    private let lock = NSLock()
    private let startup = InstalledCompletion(), stopped = InstalledCompletion()
    private let notifications = DispatchQueue(label: "darkbloom.installed-session.invalidation")
    private var phase: DistributedInstalledSessionStatus = .prepared
    private var endpoints: [ClusterRemoteWorkerEndpoint] = []
    private var relay: ClusterOwnerBootstrapRelay?
    private var pair: ClusterWorkerPair?
    private var owner: DistributedPipeExecutionOwner?
    private var stoppingTask: Task<Void, Never>?
    private var lifetime: UInt64 = 0
    private var handler: (@Sendable () -> Void)?
    private var notified = false
    private var draining = false

    public var status: DistributedInstalledSessionStatus { lock.withLock { phase } }
    public var admissionState: ClusterWorkerPairAdmissionState? { lock.withLock { pair }?.admissionState }
    public var lifetimeDeadlineUptimeNanoseconds: UInt64? { lock.withLock { lifetime == 0 ? nil : lifetime } }
    /// A fresh epoch is permitted only after all owned native and owner cleanup
    /// and both release acknowledgements. There is no implicit journal recovery.
    public var canRotate: Bool { status == .released }

    /// Call before and after LocalTokenizerLoader.load(from: model.directory).
    /// Metadata inputs remain pinned; this does not load a model container.
    public func validateModelInputs() throws { try prepared.requireUnchanged() }

    /// Metadata-only preflight, bounded independently of request deadlines. This
    /// synchronous IO belongs on the caller's startup/preparation queue.
    public static func prepare(reference: ClusterConfigurationReference) throws -> DistributedInstalledSession {
        let deadline = DispatchTime.now().uptimeNanoseconds + 15_000_000_000
        let prepared = try DistributedInstalledPreparation.prepare(reference: reference, paths: ClusterUserPaths(), deadline: deadline)
        guard prepared.plan.configuration.role == .leader else {
            throw ClusterConfigurationError.invalid("Only the configured leader starts a provider session")
        }
        return try .init(prepared: prepared)
    }

    init(prepared: DistributedInstalledPreparation, endpointFactory: @escaping EndpointFactory = DistributedInstalledSession.installedEndpoint) throws {
        self.endpointFactory = endpointFactory
        self.prepared = prepared; configuration = prepared.plan.configuration; capability = prepared.plan.capability
        model = prepared.model
        wireIdentity = prepared.plan.identity(epoch: UUID())
        expectedIdentity = .init(membershipEpoch: wireIdentity.membershipEpoch, modelID: wireIdentity.modelID,
            artifactSHA256: wireIdentity.artifactSHA256, configurationSHA256: wireIdentity.configurationSHA256,
            peers: wireIdentity.peers.map { .init(id: $0.id, buildSHA256: $0.buildSHA256) })
        let p = capability.profile
        profile = try .init(id: p.id, vocabularySize: p.vocabularySize, maxPromptTokens: p.maximumPromptTokens,
            maxOutputTokens: p.maximumOutputTokens, maxContextTokens: p.maximumContextTokens,
            requestTimeout: .seconds(configuration.requestTimeoutSeconds))
    }

    public func start() async throws {
        try lock.withLock {
            guard phase == .prepared else { throw DistributedEngineError.unavailable }
            phase = .starting
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global().async {
                    defer { self.startup.complete() }
                    do { try self.launch(); continuation.resume() }
                    catch { self.beginStop(abnormal: true); continuation.resume(throwing: error) }
                }
            }
            try Task.checkCancellation()
        } onCancel: { self.beginStop(abnormal: true) }
    }

    private func requireStarting() throws {
        guard lock.withLock({ phase == .starting }) else { throw DistributedEngineError.shuttingDown }
    }

    private func launch() throws {
        try requireStarting(); try prepared.requireUnchanged()
        let now = DispatchTime.now().uptimeNanoseconds
        let lifetime = now + prepared.plan.maximumLifetimeNanoseconds
        let startupDeadline = min(lifetime, now + 90_000_000_000)
        let relay = try ClusterOwnerBootstrapRelay(identity: wireIdentity,
            executionPlanSHA256: prepared.plan.partition.planSHA256,
            deadlineUptimeNanoseconds: min(startupDeadline, now + 30_000_000_000))
        lock.withLock { self.lifetime = lifetime; self.relay = relay }
        for rank in 0..<2 {
            try requireStarting()
            let endpoint = try endpointFactory(prepared.plan, wireIdentity, rank, lifetime, relay)
            let stopped = lock.withLock { endpoints.append(endpoint); return phase != .starting }
            if stopped { endpoint.requestNativeCleanup(); throw DistributedEngineError.shuttingDown }
        }
        let values = lock.withLock { endpoints }
        let pair = try ClusterWorkerPair(workers: values, startupDeadline: startupDeadline, maximumRequests: capability.maxRequests)
        lock.withLock { self.pair = pair }
        let owner = try DistributedPipeExecutionOwner(pair: pair, profile: profile, chunkSize: configuration.chunkTokens)
        owner.setReadinessInvalidationHandler { [weak self] in self?.beginStop(abnormal: true) }
        try lock.withLock {
            guard phase == .starting, owner.readiness() != nil else { throw DistributedEngineError.unavailable }
            self.owner = owner; phase = .ready
        }
    }

    private static func installedEndpoint(plan: DistributedInstalledPlan, wireIdentity: ClusterWorkerIdentity,
        rank: Int, lifetime: UInt64, relay: ClusterOwnerBootstrapRelay) throws -> ClusterRemoteWorkerEndpoint {
        let peer = plan.configuration.peers[rank]
        let endpoint: ClusterRemoteWorkerEndpoint
        if rank == plan.configuration.localRank {
            endpoint = try .init(localOwner: .init(installedDarkbloom: URL(fileURLWithPath: peer.ownerExecutable)),
                clusterID: plan.configuration.clusterID, expectedIdentity: wireIdentity, profile: plan.capability.profile, rank: rank,
                executionPlanSHA256: plan.partition.planSHA256,
                lifetimeDeadlineUptimeNanoseconds: lifetime, bootstrapRelay: relay)
        } else {
            let ssh = try ClusterSSHConfiguration(host: peer.host, user: peer.user, port: peer.port,
                knownHostsFile: URL(fileURLWithPath: plan.configuration.trust.knownHostsFile),
                identityFile: URL(fileURLWithPath: plan.configuration.trust.identityFile), installedDarkbloom: peer.ownerExecutable)
            endpoint = try .init(configuration: ssh, clusterID: plan.configuration.clusterID,
                expectedIdentity: wireIdentity, profile: plan.capability.profile, rank: rank,
                executionPlanSHA256: plan.partition.planSHA256,
                lifetimeDeadlineUptimeNanoseconds: lifetime, bootstrapRelay: relay)
        }
        return endpoint
    }

    /// Bound the caller's wait only. Work and ownership continue if proof is
    /// missing; the retained session must remain in the registry's quarantine.
    public func stop(until deadline: UInt64) async -> DistributedInstalledSessionStatus {
        lock.withLock { draining = false }
        beginStop(abnormal: false)
        let finished = await stopped.wait(until: deadline)
        if !finished { lock.withLock { if phase != .released { phase = .quarantined } } }
        return status
    }

    /// Remove from routing first, then wait for the current request's normal
    /// retirement AND explicit resource release before shutting down the owners.
    public func drain(until deadline: UInt64) async -> DistributedInstalledSessionStatus {
        let value = lock.withLock { () -> ClusterWorkerPair? in
            if phase == .ready { phase = .draining; draining = true }
            return pair
        }
        value?.stopAcceptingRequests()
        beginStop(abnormal: false)
        let finished = await stopped.wait(until: deadline)
        if !finished { lock.withLock { if phase != .released { phase = .quarantined } } }
        return status
    }

    func beginStop(abnormal: Bool) {
        let result = lock.withLock { () -> ([ClusterRemoteWorkerEndpoint], ClusterOwnerBootstrapRelay?, (@Sendable () -> Void)?) in
            if phase == .released { return ([], nil, nil) }
            let wasPrepared = phase == .prepared
            if abnormal { draining = false }
            phase = abnormal ? .quarantined : (phase == .quarantined ? .quarantined : (draining ? .draining : .stopping))
            if wasPrepared { startup.complete() }
            if stoppingTask == nil { stoppingTask = Task { await self.finishStop() } }
            let notify: (@Sendable () -> Void)?
            if !draining, !notified, let handler { notified = true; notify = handler } else { notify = nil }
            return (abnormal || pair == nil ? endpoints : [], relay, notify)
        }
        result.1?.cancel()
        for endpoint in result.0 { endpoint.requestNativeCleanup() }
        // An abnormal stop can interrupt a previously started graceful drain.
        // Pair.shutdown owns cancellation/actual retirement and is idempotent.
        if let pair = lock.withLock({ draining ? nil : self.pair }) {
            Task { await pair.shutdown() }
        }
        if let notify = result.2 { notifications.async(execute: notify) }
    }

    private func finishStop() async {
        await startup.value()
        let values = lock.withLock { (pair, endpoints, lifetime, draining) }
        if let pair = values.0 {
            if values.3 { await pair.drainAndShutdown() } else { await pair.shutdown() }
        }
        else {
            for endpoint in values.1 { endpoint.requestNativeCleanup() }
            for endpoint in values.1 { await endpoint.waitUntilNativeCleanup() }
        }
        var released = true
        for endpoint in values.1 {
            let deadline = max(values.2, DispatchTime.now().uptimeNanoseconds) + 3_000_000_000
            if !(await endpoint.waitUntilOwnerReleased(deadline: deadline)) { released = false }
        }
        lock.withLock { phase = released ? .released : .quarantined }
        stopped.complete()
    }

    func activeOwner(forReservation: Bool = false) throws -> DistributedPipeExecutionOwner {
        try lock.withLock {
            guard let owner, let pair else { throw DistributedEngineError.unavailable }
            let state = pair.admissionState
            guard phase == .ready || (!forReservation && phase == .draining && state.hasActiveRequest),
                  state.remainingLifetimeNanoseconds > 0,
                  state.admissionsRemaining > 0 || (!forReservation && state.hasActiveRequest),
                  !forReservation || state.canAdmit() else { throw DistributedEngineError.unavailable }
            return owner
        }
    }

    func installInvalidationHandler(_ value: @escaping @Sendable () -> Void) {
        let notify = lock.withLock { () -> Bool in
            handler = value
            if [.stopping, .quarantined, .released].contains(phase), !notified { notified = true; return true }
            return false
        }
        if notify { notifications.async(execute: value) }
    }

    func waitForStop() async { beginStop(abnormal: false); await stopped.value() }
}

private final class InstalledCompletion: @unchecked Sendable {
    private let lock = NSLock(), group = DispatchGroup()
    private var finished = false
    init() { group.enter() }
    func complete() { if lock.withLock({ if finished { return false }; finished = true; return true }) { group.leave() } }
    func value() async { await withCheckedContinuation { continuation in group.notify(queue: .global()) { continuation.resume() } } }
    func wait(until deadline: UInt64) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: self.group.wait(timeout: .init(uptimeNanoseconds: deadline)) == .success) }
        }
    }
}
