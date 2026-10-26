import Foundation
import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
import DarkbloomClusterRemote

public enum DistributedInstalledSessionStatus: String, Sendable {
    case prepared, starting, ready, draining, stopping, quarantined, released
}

/// The follower member refused the session the leader opened (for example a
/// setup for another plan); nothing was launched on its Mac. The reason is the
/// follower's own (bounded by the link), printed as plain ASCII.
public struct DistributedInstalledStartRefusal: Error, CustomStringConvertible, Equatable, Sendable {
    public let rank: Int
    public let reason: String
    init(rank: Int, reason: String) {
        self.rank = rank
        self.reason = String(String.UnicodeScalarView(reason.unicodeScalars.prefix(256).map {
            (32...126).contains($0.value) ? $0 : "?" }))
    }
    public var description: String {
        "The follower member (rank \(rank)) refused the session: \(reason.isEmpty ? "no reason given" : reason)"
    }
}

/// SSH to the other Mac is a developer and test harness only (owner gate,
/// 2026-10-11: no SSH in the user path). The product reaches the follower over
/// the link control channel (a setup with `linkControl`, made by pairing). A
/// setup that reaches it over SSH (`trust`, no `linkControl`) serves only in a
/// process started with `DARKBLOOM_CLUSTER_DEVELOPER_SSH=1`, which nothing in
/// the product sets and the setup never offers.
public enum DistributedInstalledDeveloperSSH {
    public static let environmentKey = "DARKBLOOM_CLUSTER_DEVELOPER_SSH"

    public static func enabled(_ environment: [String: String]) -> Bool { environment[environmentKey] == "1" }

    /// Refuses a setup whose follower is reached over SSH unless the developer
    /// flag is set. A link control setup always passes.
    static func requireFollowerRoute(_ configuration: ClusterConfiguration,
                                     environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard configuration.linkControl == nil, !enabled(environment) else { return }
        throw ClusterConfigurationError.invalid("This setup reaches the other Mac over SSH, which Darkbloom no longer uses for serving. Run `darkbloom cluster` on both Macs to pair them again")
    }
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
    /// The same with the rank's data-plane credential line (S16), or nil.
    typealias KeyedEndpointFactory = @Sendable (DistributedInstalledPlan, ClusterWorkerIdentity, Int, UInt64,
        (any ClusterOwnerBootstrapExchange)?, DistributedInstalledLinkLeader?, Data?) throws -> any ClusterOwnedWorkerEndpoint
    private let endpointFactory: KeyedEndpointFactory
    /// S16: whether this session keys its data plane: the installed worker
    /// carries the keyed data plane and both ranks run the same build. Each
    /// rank then gets its own credential on its owner route, and the pair is
    /// ready only with one encrypted, peer-verified session on both ranks.
    let keysDataPlane: Bool
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
    private var abnormalStop = false
    /// A stop was asked for (`stop`, `drain`) before any loss of readiness:
    /// the workers' exit that follows is that stop, not a lost rank.
    private var stopRequested = false
    /// Bounds the stop's waits once a stop nobody asked for began (see the type).
    private let stopBound: DistributedInstalledStopBound
    private var stopDetailText: String?
    private var routingNoteText: String?
    /// How this session routes requests (`ClusterRequestRoutingBasis`), once started.
    public var routingNote: String? { lock.withLock { routingNoteText } }
    /// Why an unresolved stop is unresolved (S24): which rank's proof is
    /// missing and what its endpoint knows about it.
    public var stopDetail: String? { lock.withLock { stopDetailText } }

    public var status: DistributedInstalledSessionStatus { lock.withLock { phase } }
    public var admissionState: ClusterWorkerPairAdmissionState? { lock.withLock { pair }?.admissionState }
    /// The pair's batch lanes, from the plan the pair starts with
    /// (`DistributedInstalledPlan.batchLanes`), known before it starts.
    public var concurrentRequests: Int { prepared.plan.batchLanes() ?? 1 }
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
            collectiveProgressLimitMilliseconds: DistributedInstalledPlan.collectiveProgressLimitMilliseconds,
            encryptedDataPlane: values.1?.readiness.map(\.encryptedDataPlane),
            peerVerified: values.1?.readiness.map(\.peerVerified))
    }

    /// Identifiers, mode, cut and owner diagnostics for incidents and telemetry (S24).
    public var observabilityFacts: DistributedSessionFacts {
        let values = lock.withLock { (endpoints, observedMembershipEpoch ?? wireIdentity.membershipEpoch, pair?.lastRequestFailure, stopDetailText) }
        let ordered = values.0.sorted { $0.rank < $1.rank }
        let terminations = ordered.compactMap { endpoint -> String? in
            let ended: String?
            switch endpoint.ownerTermination {
            case .launchFailed?: ended = "rank \(endpoint.rank) ended: its owner could not be launched"
            case .exited(let status)?: ended = "rank \(endpoint.rank) ended: its owner exited with status \(status)"
            case .signalled(let signal)?: ended = "rank \(endpoint.rank) ended: its owner was terminated by signal \(signal)"
            case nil: ended = nil
            }
            // The follower's own words on the same line, so the incident names why.
            guard let ended, let said = (endpoint as? ClusterLinkWorkerEndpoint)?.followerReason else { return ended }
            return ended + " (the follower said: " + said + ")"
        }
        return .init(clusterID: configuration.clusterID, memberID: configuration.memberID, modelID: model.publicModelID,
            mode: configuration.selectedGenerationMode.rawValue,
            cut: DistributedSessionFacts.cut(prepared.plan.partition.stages.map { ($0.rank, $0.sourceLayerStart, $0.sourceLayerEnd) },
                mode: configuration.selectedGenerationMode, tensorShares: configuration.tensorShares),
            membershipEpoch: values.1.uuidString.lowercased(),
            // The last request failure comes last: the classifier scans newest first (S24).
            diagnostics: (ordered.compactMap(Self.diagnostic) + [values.3, values.2].compactMap { $0 }).filter { !$0.isEmpty },
            terminations: terminations, peerHosts: configuration.peers.map(\.host), peerUsers: configuration.peers.map(\.user),
            ranks: configuration.peers.sorted { $0.rank < $1.rank }.map(\.id))
    }

    /// One rank's diagnostics for an incident: an SSH owner's standard-error
    /// tail, or why a link follower refused the open (the leader's own error
    /// is then only that the link closed).
    static func diagnostic(_ endpoint: any ClusterOwnedWorkerEndpoint) -> String? {
        if let remote = endpoint as? ClusterRemoteWorkerEndpoint { return DistributedSessionFacts.tail(remote.diagnosticTail) }
        if let link = endpoint as? ClusterLinkWorkerEndpoint, let reason = link.refusalReason {
            return "rank \(endpoint.rank) follower refused the open: \(reason.isEmpty ? "no reason given" : String(reason.prefix(512)))"
        }
        // How the follower's own owner or worker ended, in its words (e.g. its
        // memory gate refused the load), and why it was declared lost, not
        // only that its endpoint closed.
        if let link = endpoint as? ClusterLinkWorkerEndpoint {
            let said = link.followerReason.map { "rank \(endpoint.rank) follower said: \(String($0.prefix(512)))" }
            let lost = link.lossReason.map { "rank \(endpoint.rank) follower lost: \(String($0.prefix(512)))" }
            let both = [said, lost].compactMap { $0 }
            if !both.isEmpty { return both.joined(separator: "; ") }
        }
        return nil
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
        Self.unrequestedStopAllowance(prepared)
    }

    static func unrequestedStopAllowance(_ prepared: DistributedInstalledPreparation) -> UInt64 {
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
        // Before anything is launched: a setup that would reach the follower
        // over SSH is refused outside the developer harness.
        try DistributedInstalledDeveloperSSH.requireFollowerRoute(prepared.plan.configuration)
        return try .init(prepared: prepared)
    }

    /// Stand-ins and checks: a factory without credentials, a plaintext data plane.
    convenience init(prepared: DistributedInstalledPreparation, endpointFactory: @escaping EndpointFactory) throws {
        try self.init(prepared: prepared, keyedEndpointFactory: { plan, identity, rank, lifetime, relay, link, _ in
            try endpointFactory(plan, identity, rank, lifetime, relay, link)
        }, keysDataPlane: false)
    }

    init(prepared: DistributedInstalledPreparation,
         keyedEndpointFactory: @escaping KeyedEndpointFactory = DistributedInstalledSession.installedEndpoint,
         keysDataPlane: Bool? = nil) throws {
        try prepared.plan.configuration.requireOrdinarySessionRoute()
        self.endpointFactory = keyedEndpointFactory
        let peers = prepared.plan.configuration.peers
        self.keysDataPlane = try ClusterMiMoPrivateImagePolicy.keysDataPlane(prepared.plan.capability,
            supported: prepared.validation.workerFeatures.acceptsDataPlane,
            sameBuild: Set(prepared.plan.identity(epoch: UUID()).peers.map(\.buildSHA256)).count == 1 && peers.count == 2,
            hasLink: prepared.plan.configuration.linkControl != nil, selectionOverride: keysDataPlane)
        self.prepared = prepared; configuration = prepared.plan.configuration; capability = prepared.plan.capability
        // A body still running when the bound ends goes on by itself (the
        // pair's shutdown is idempotent and keeps its own state; the endpoints
        // keep ownership unresolved).
        stopBound = .init(allowanceNanoseconds: Self.unrequestedStopAllowance(prepared))
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
            // A stop that came before the link existed is seen here; one during the wait cancels it (`beginStop`).
            try requireStarting()
            try leader.waitForFollower(until: min(startupDeadline, DispatchTime.now().uptimeNanoseconds + 30_000_000_000))
        }
        let credentials: [Data?] = keysDataPlane
            ? try ClusterDataPlaneLaunch.sessionCredentialLines(epoch: wireIdentity.membershipEpoch) : [nil, nil]
        for rank in 0..<2 {
            try requireStarting()
            let endpoint = try endpointFactory(prepared.plan, wireIdentity, rank, lifetime, relay, link, credentials[rank])
            let stopped = lock.withLock { endpoints.append(endpoint); return phase != .starting }
            if stopped { endpoint.requestNativeCleanup(); throw DistributedEngineError.shuttingDown }
        }
        let values = lock.withLock { endpoints }
        let pair: ClusterWorkerPair
        do {
            pair = try ClusterWorkerPair(workers: values, startupDeadline: startupDeadline,
                timing: prepared.plan.budgets.pairTiming, keepWarm: .standard,
                lanes: concurrentRequests, lanesRetireAlone: prepared.plan.lanesRetireAlone())
        } catch { throw Self.startFailure(error, endpoints: values) }
        lock.withLock { self.pair = pair }
        // Per-request route (pair, or the member holding the whole model alone), derived from this setup.
        let routing = ClusterRequestRoutingBasis.make(plan: prepared.plan,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            deadline: DispatchTime.now().uptimeNanoseconds + 15_000_000_000)
        lock.withLock { routingNoteText = routing.note }
        let owner = try DistributedPipeExecutionOwner(pair: pair, profile: profile, chunkSize: configuration.chunkTokens,
            routing: routing.routing)
        owner.setReadinessInvalidationHandler { [weak self] in self?.beginStop(abnormal: true) }
        // S16: a keyed session is ready only when both ranks report the same
        // encrypted data plane with each peer verified against its pin.
        if keysDataPlane {
            guard let ready = pair.readiness, ready.encryptedDataPlane, ready.peerVerified else {
                throw DistributedEngineError.unavailable
            }
        }
        // The link as this load measured it (every load over the cable measures it, pipeline or tensor parallel):
        // the next plan of this pair uses it, with no user step.
        if let probe = values.compactMap({ $0.readiness?.linkProbe }).first {
            ClusterLinkProbeHistory.record(probe, members: wireIdentity.peers.map(\.id),
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        }
        try lock.withLock {
            guard phase == .starting, owner.readiness() != nil else { throw DistributedEngineError.unavailable }
            self.observedMembershipEpoch = pair.readiness?.identity.membershipEpoch
            self.owner = owner; phase = .ready
        }
    }

    /// A follower member that refuses the open reaches the pair only as a
    /// closed stream; the start then fails with the follower's own reason.
    /// Any other failure is returned unchanged. The coordinator-formed pair
    /// (`ClusterPairServingContext.pairOwner`) uses the same rule.
    static func startFailure(_ error: Error, endpoints: [any ClusterWorkerEndpoint]) -> Error {
        for case let link as ClusterLinkWorkerEndpoint in endpoints {
            if let reason = link.refusalReason { return DistributedInstalledStartRefusal(rank: link.rank, reason: reason) }
        }
        return error
    }

    private static func installedEndpoint(plan: DistributedInstalledPlan, wireIdentity: ClusterWorkerIdentity,
        rank: Int, lifetime: UInt64, relay: (any ClusterOwnerBootstrapExchange)?,
        link: DistributedInstalledLinkLeader?, dataPlaneTrust: Data?) throws -> any ClusterOwnedWorkerEndpoint {
        let peer = plan.configuration.peers[rank]
        let endpoint: any ClusterOwnedWorkerEndpoint
        if rank == plan.configuration.localRank {
            endpoint = try ClusterRemoteWorkerEndpoint(localOwner: .init(installedDarkbloom: URL(fileURLWithPath: peer.ownerExecutable)),
                clusterID: plan.configuration.clusterID, expectedIdentity: wireIdentity, profile: plan.capability.profile, rank: rank,
                executionPlanSHA256: plan.partition.planSHA256,
                lifetimeDeadlineUptimeNanoseconds: lifetime, bootstrapRelay: relay, dataPlaneTrust: dataPlaneTrust)
        } else if let link {
            // No SSH: the follower member serves this rank over the link.
            // The private image candidate carries only this rank's credential
            // over the existing authenticated encrypted control channel. Text
            // setups keep their legacy nil credential and plaintext native path.
            let trust = try ClusterMiMoPrivateImagePolicy.followerDataPlaneTrust(plan.capability,
                line: dataPlaneTrust, epoch: wireIdentity.membershipEpoch, rank: rank)
            endpoint = try link.endpoint(plan: plan, identity: wireIdentity, rank: rank, lifetime: lifetime,
                relay: relay, dataPlaneTrust: trust)
        } else {
            try DistributedInstalledDeveloperSSH.requireFollowerRoute(plan.configuration)
            guard let trust = plan.configuration.trust else {
                throw ClusterConfigurationError.invalid("This setup has neither SSH trust nor a link control attachment for its follower")
            }
            let ssh = try ClusterSSHConfiguration(host: peer.host, user: peer.user, port: peer.port,
                knownHostsFile: URL(fileURLWithPath: trust.knownHostsFile),
                identityFile: URL(fileURLWithPath: trust.identityFile), installedDarkbloom: peer.ownerExecutable)
            endpoint = try ClusterRemoteWorkerEndpoint(configuration: ssh, clusterID: plan.configuration.clusterID,
                expectedIdentity: wireIdentity, profile: plan.capability.profile, rank: rank,
                executionPlanSHA256: plan.partition.planSHA256,
                lifetimeDeadlineUptimeNanoseconds: lifetime, bootstrapRelay: relay, dataPlaneTrust: dataPlaneTrust)
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
            if !abnormal, !abnormalStop { stopRequested = true }
            if abnormal { draining = false; abnormalStop = true; stopBound.beginUnrequested() }
            phase = abnormal ? .quarantined : (phase == .quarantined ? .quarantined : (draining ? .draining : .stopping))
            if wasPrepared { startup.complete() }
            if stoppingTask == nil { stoppingTask = Task { await self.finishStop() } }
            let notify: (@Sendable () -> Void)?
            if !draining, !notified, let handler { notified = true; notify = handler } else { notify = nil }
            return (abnormal || pair == nil ? endpoints : [], relay, notify)
        }
        if let notice { let value = stopNotice; notifications.async { notice(value) } }
        result.1?.cancel()
        // A rank 0 still waiting for its follower stops waiting now (a stop during start must not wait for that deadline).
        lock.withLock { link }?.cancelStart()
        // The fence names its cause on the other Mac as well (S24).
        // A requested stop keeps its cause when its own workers' exit follows, so
        // neither Mac journals a planned stop as an incident (ClusterSessionStopCause).
        let cause = lock.withLock {
            ClusterSessionStopCause.fenceCause(unrequested: abnormalStop, requestedFirst: stopRequested,
                                               lastFailure: pair?.lastRequestFailure)
        }
        for endpoint in result.0 { endpoint.requestNativeCleanup(reason: cause) }
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
        // After a stop nobody asked for, the ranks have the collective progress
        // limit to leave their exchange and the model's stop margin to give the
        // memory back (`unrequestedStopAllowanceNanoseconds`, derived from the
        // plan), counted from that stop: the rest of the stop is bounded by it,
        // not by any owner's lease, also when it interrupts a graceful stop
        // whose waits are already under way (`stopBound`).
        if let pair = values.0 {
            if values.2 { _ = await stopBound.wait(until: nil) { await pair.drainAndShutdown(); return true } }
            else { _ = await stopBound.wait(until: nil) { await pair.shutdown(); return true } }
        }
        else {
            for endpoint in values.1 { endpoint.requestNativeCleanup() }
            for endpoint in values.1 { await endpoint.waitUntilNativeCleanup() }
        }
        var released = true
        var missing: [String] = []
        for endpoint in values.1 {
            // Each owner keeps its own retirement ceiling past its last lease
            // grant, which the endpoint tracks; a release acknowledgement cannot
            // arrive later than that. After an unrequested stop the allowance
            // above bounds the wait instead.
            let ceiling = max(endpoint.ownerRetirementDeadlineUptimeNanoseconds, DispatchTime.now().uptimeNanoseconds) + 3_000_000_000
            let deadline = stopBound.cut(ceiling) ?? ceiling
            let proved = await stopBound.wait(until: deadline) { await endpoint.waitUntilOwnerReleased(deadline: deadline) } ?? false
            if !proved {
                released = false
                missing.append("rank \(endpoint.rank): no release proof"
                    + (stopBound.isUnrequested ? " within \(unrequestedStopAllowanceNanoseconds / 1_000_000_000) s of the stop" : "")
                    + ((endpoint as? ClusterLinkWorkerEndpoint).map { " (\($0.diagnosticSummary))" } ?? "")
                    + ((endpoint as? ClusterRemoteWorkerEndpoint)?.unresolvedReason.map { " (\($0))" } ?? ""))
            }
        }
        lock.withLock { stopDetailText = missing.isEmpty ? nil : missing.joined(separator: "; ") }
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
