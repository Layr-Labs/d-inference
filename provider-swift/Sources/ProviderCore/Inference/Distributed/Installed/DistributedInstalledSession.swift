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
    private let diagnosticBinding: ClusterStatusBinding
    private var observedMembershipEpoch: UUID?
    private let wireIdentity: ClusterWorkerIdentity
    /// The relay is present exactly when the installed bootstrap is the
    /// owner-authenticated one; the link leader exactly when the setup reaches
    /// its follower over the link control channel.
    typealias EndpointFactory = @Sendable (DistributedInstalledPlan, ClusterWorkerIdentity, Int, UInt64,
        (any ClusterOwnerBootstrapExchange)?, DistributedInstalledLinkLeader?) throws -> any ClusterOwnedWorkerEndpoint
    private let endpointFactory: EndpointFactory
    private let lock = NSLock()
    private let startup = InstalledCompletion(), stopped = InstalledCompletion()
    private let notifications = DispatchQueue(label: "darkbloom.installed-session.invalidation")
    private var phase: DistributedInstalledSessionStatus = .prepared
    private var endpoints: [any ClusterOwnedWorkerEndpoint] = []
    private var relay: ClusterOwnerBootstrapRelay?
    private var link: DistributedInstalledLinkLeader?
    private var pair: ClusterWorkerPair?
    private var owner: DistributedPipeExecutionOwner?
    private var stoppingTask: Task<Void, Never>?
    private var handler: (@Sendable () -> Void)?
    private var notified = false
    private var draining = false
    private var stopNoticeHandler: (@Sendable (DistributedInstalledStopNotice) -> Void)?
    private var stopNoticePending = false

    public var status: DistributedInstalledSessionStatus { lock.withLock { phase } }
    public var admissionState: ClusterWorkerPairAdmissionState? { lock.withLock { pair }?.admissionState }
    /// A fresh epoch is permitted only after all owned native and owner cleanup
    /// and both release acknowledgements. There is no implicit journal recovery.
    public var canRotate: Bool { status == .released }


    /// Sample retained ownership directly. A PID or saved configuration never
    /// establishes readiness, and no remote uptime participates in this sample.
    public var diagnosticObservation: ClusterSessionObservation {
        let values = lock.withLock { (endpoints, pair, observedMembershipEpoch) }
        let members = configuration.peers.map { peer -> ClusterSessionObservation.Member in
            let endpoint = values.0.first { $0.rank == peer.rank }
            let ready = endpoint?.readiness
            let termination: ClusterSessionObservation.Termination?
            switch endpoint?.ownerTermination {
            case .launchFailed?: termination = .init(kind: .launchFailed, status: nil)
            case .exited(let status)?: termination = .init(kind: .exited, status: status)
            case .signalled(let status)?: termination = .init(kind: .signalled, status: status)
            case nil: termination = nil
            }
            return .init(peerID: peer.id, rank: peer.rank,
                transport: peer.rank == configuration.localRank ? .localPipes : (configuration.linkControl == nil ? .authenticatedSSH : .linkControl),
                nativeReady: ready != nil, requestCapacityBytes: ready?.requestCapacityBytes,
                nativeCleanupObserved: endpoint?.nativeCleanupObserved ?? false,
                ownerReleaseAcknowledged: endpoint?.ownerDeviceLeaseReleasedObserved ?? false,
                ownerTermination: termination)
        }
        let state = values.1?.admissionState
        let phase = status
        let speculation = DistributedInstalledSpeculation(configuration: configuration, capability: prepared.plan.capability)
        let ready = values.1?.readiness != nil && members.allSatisfy(\.nativeReady)
            && state?.isValid == true
            && (phase == .ready || (phase == .draining && state?.hasActiveRequest == true))
        return .init(binding: diagnosticBinding, phase: phase.rawValue,
            observedMembershipEpoch: values.2?.uuidString.lowercased(),
            observedPrefillSchedule: values.2 == nil ? nil : configuration.selectedPrefillSchedule,
            observedGenerationMode: values.2 == nil ? nil : configuration.selectedGenerationMode,
            ready: ready, admission: state.map { .init(requestsServed: $0.requestsServed,
                keepWarmExchanges: $0.keepWarmExchanges, activeRequest: $0.hasActiveRequest,
                draining: $0.isDraining, valid: $0.isValid) }, members: members,
            mtpEnabled: speculation.enabled, mtpOffReason: speculation.offReason,
            nativeBootstrap: prepared.plan.bootstrap,
            collectiveProgressLimitMilliseconds: DistributedInstalledPlan.collectiveProgressLimitMilliseconds)
    }

    /// Longest a stop can legitimately take. A request that is still running
    /// is first given the selected model's clean-stop wait to end at a token.
    /// If it is cancelled instead, a rank still inside a collective when its
    /// peer went away ends itself at the progress limit, then releases its
    /// model within the selected model's stop margin.
    public var cooperativeStopAllowanceNanoseconds: UInt64 {
        prepared.plan.budgets.cleanStopWaitNanoseconds + unrequestedStopAllowanceNanoseconds
    }

    /// The same for a stop nobody asked for (a rank was lost, or a request had
    /// to be cancelled): no clean-stop wait precedes it.
    var unrequestedStopAllowanceNanoseconds: UInt64 {
        UInt64(DistributedInstalledPlan.collectiveProgressLimitMilliseconds) * 1_000_000 + prepared.plan.budgets.stopMarginNanoseconds
    }

    /// One call at most, at the moment a session that was serving stops
    /// without having been asked to. Installing the handler after that moment
    /// delivers the notice at once.
    public func installStopNoticeHandler(_ value: @escaping @Sendable (DistributedInstalledStopNotice) -> Void) {
        let notify = lock.withLock { () -> Bool in
            stopNoticeHandler = value
            if stopNoticePending { stopNoticePending = false; return true }
            return false
        }
        if notify { notifications.async { value(self.stopNotice) } }
    }

    private var stopNotice: DistributedInstalledStopNotice {
        .init(longestWaitNanoseconds: unrequestedStopAllowanceNanoseconds,
              progressLimitMilliseconds: DistributedInstalledPlan.collectiveProgressLimitMilliseconds)
    }

    /// The selected model's first-token allowance. It does not depend on the
    /// generation mode: under phase split the first token is still selected by
    /// the pair, before the hand-off.
    public func firstTokenBudgetPolicy() throws -> DistributedFirstTokenBudgetPolicy {
        try .init(baseMilliseconds: prepared.plan.budgets.firstTokenBaseMilliseconds,
                  millisecondsPerInputToken: prepared.plan.budgets.firstTokenMillisecondsPerPromptToken)
    }

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
        try prepared.plan.configuration.requireOrdinarySessionRoute()
        self.endpointFactory = endpointFactory
        self.prepared = prepared; configuration = prepared.plan.configuration; capability = prepared.plan.capability
        diagnosticBinding = try ClusterStatusBinding(configuration: configuration, capability: capability)
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
        // No fixed lifetime: each owner is opened with one rank-lease grant
        // and its endpoint renews it while this session keeps the pair.
        let lifetime = now + ClusterWorkerLease.maximumNanoseconds
        let startupDeadline = now + prepared.plan.budgets.startupAllowanceNanoseconds
        // No relay exists for the direct native bootstrap: the owners carry no
        // bootstrap rounds and the status reports the exchange as unauthenticated.
        // The owner-authenticated one carries the committed native starts this
        // leader mints for both ranks (each owner admits only its own setup's).
        let bootstrapProfile = prepared.plan.bootstrap.ownerProfile
        let relay = try bootstrapProfile.map { profile in
            try ClusterOwnerBootstrapRelay(identity: wireIdentity, executionPlanSHA256: prepared.plan.partition.planSHA256,
                profile: profile, deadlineUptimeNanoseconds: min(startupDeadline, now + 30_000_000_000),
                nativeStarts: profile.carriesNativeStart
                    ? try DistributedInstalledNativeStart.starts(plan: prepared.plan, epoch: wireIdentity.membershipEpoch) : [])
        }
        lock.withLock { self.relay = relay }
        // The follower reached over the link control channel must be connected
        // before its rank is opened.
        var link: DistributedInstalledLinkLeader?
        if configuration.linkControl != nil {
            let leader = try DistributedInstalledLinkLeader(configuration: configuration)
            lock.withLock { self.link = leader }
            link = leader
            try leader.waitForFollower(until: min(startupDeadline, DispatchTime.now().uptimeNanoseconds + 30_000_000_000))
        }
        for rank in 0..<2 {
            try requireStarting()
            let endpoint = try endpointFactory(prepared.plan, wireIdentity, rank, lifetime, relay, link)
            let stopped = lock.withLock { endpoints.append(endpoint); return phase != .starting }
            if stopped { endpoint.requestNativeCleanup(); throw DistributedEngineError.shuttingDown }
        }
        let values = lock.withLock { endpoints }
        let pair = try ClusterWorkerPair(workers: values, startupDeadline: startupDeadline,
            timing: prepared.plan.budgets.pairTiming, keepWarm: .standard)
        lock.withLock { self.pair = pair }
        let owner = try DistributedPipeExecutionOwner(pair: pair, profile: profile, chunkSize: configuration.chunkTokens)
        owner.setReadinessInvalidationHandler { [weak self] in self?.beginStop(abnormal: true) }
        try lock.withLock {
            guard phase == .starting, owner.readiness() != nil else { throw DistributedEngineError.unavailable }
            self.observedMembershipEpoch = pair.readiness?.identity.membershipEpoch
            self.owner = owner; phase = .ready
        }
    }

    private static func installedEndpoint(plan: DistributedInstalledPlan, wireIdentity: ClusterWorkerIdentity,
        rank: Int, lifetime: UInt64, relay: (any ClusterOwnerBootstrapExchange)?,
        link: DistributedInstalledLinkLeader?) throws -> any ClusterOwnedWorkerEndpoint {
        let peer = plan.configuration.peers[rank]
        let endpoint: any ClusterOwnedWorkerEndpoint
        if rank == plan.configuration.localRank {
            endpoint = try ClusterRemoteWorkerEndpoint(localOwner: .init(installedDarkbloom: URL(fileURLWithPath: peer.ownerExecutable)),
                clusterID: plan.configuration.clusterID, expectedIdentity: wireIdentity, profile: plan.capability.profile, rank: rank,
                executionPlanSHA256: plan.partition.planSHA256,
                lifetimeDeadlineUptimeNanoseconds: lifetime, bootstrapRelay: relay)
        } else if let link {
            // No SSH: the follower member serves this rank over the link.
            endpoint = try link.endpoint(plan: plan, identity: wireIdentity, rank: rank, lifetime: lifetime, relay: relay)
        } else {
            guard let trust = plan.configuration.trust else {
                throw ClusterConfigurationError.invalid("This setup has neither SSH trust nor a link control attachment for its follower")
            }
            let ssh = try ClusterSSHConfiguration(host: peer.host, user: peer.user, port: peer.port,
                knownHostsFile: URL(fileURLWithPath: trust.knownHostsFile),
                identityFile: URL(fileURLWithPath: trust.identityFile), installedDarkbloom: peer.ownerExecutable)
            endpoint = try ClusterRemoteWorkerEndpoint(configuration: ssh, clusterID: plan.configuration.clusterID,
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
        var notice: (@Sendable (DistributedInstalledStopNotice) -> Void)?
        let result = lock.withLock { () -> ([any ClusterOwnedWorkerEndpoint], ClusterOwnerBootstrapRelay?, (@Sendable () -> Void)?) in
            if phase == .released { return ([], nil, nil) }
            let wasPrepared = phase == .prepared
            // Serving ended without a request to end it: say so now, before
            // the wait for the workers, which can be the whole progress limit.
            // A drain was asked for; its own workers' exit reaches here as an
            // invalidation and is not announced.
            if abnormal, phase == .ready {
                if let stopNoticeHandler { notice = stopNoticeHandler } else { stopNoticePending = true }
            }
            if abnormal { draining = false }
            phase = abnormal ? .quarantined : (phase == .quarantined ? .quarantined : (draining ? .draining : .stopping))
            if wasPrepared { startup.complete() }
            if stoppingTask == nil { stoppingTask = Task { await self.finishStop() } }
            let notify: (@Sendable () -> Void)?
            if !draining, !notified, let handler { notified = true; notify = handler } else { notify = nil }
            return (abnormal || pair == nil ? endpoints : [], relay, notify)
        }
        if let notice { let value = stopNotice; notifications.async { notice(value) } }
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
        let values = lock.withLock { (pair, endpoints, draining) }
        if let pair = values.0 {
            if values.2 { await pair.drainAndShutdown() } else { await pair.shutdown() }
        }
        else {
            for endpoint in values.1 { endpoint.requestNativeCleanup() }
            for endpoint in values.1 { await endpoint.waitUntilNativeCleanup() }
        }
        var released = true
        for endpoint in values.1 {
            // Each owner keeps its own retirement ceiling past its last lease
            // grant, which the endpoint tracks; a release acknowledgement cannot
            // arrive later than that.
            let deadline = max(endpoint.ownerRetirementDeadlineUptimeNanoseconds, DispatchTime.now().uptimeNanoseconds) + 3_000_000_000
            if !(await endpoint.waitUntilOwnerReleased(deadline: deadline)) { released = false }
        }
        // The follower's proofs have arrived (or will not): the edge closes.
        lock.withLock { link }?.stop()
        lock.withLock { phase = released ? .released : .quarantined }
        stopped.complete()
    }

    func activeOwner(forReservation: Bool = false) throws -> DistributedPipeExecutionOwner {
        try lock.withLock {
            guard let owner, let pair else { throw DistributedEngineError.unavailable }
            let state = pair.admissionState
            guard phase == .ready || (!forReservation && phase == .draining && state.hasActiveRequest),
                  state.isValid || (!forReservation && state.hasActiveRequest),
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
