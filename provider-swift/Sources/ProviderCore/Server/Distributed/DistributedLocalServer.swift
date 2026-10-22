import Foundation
import Hummingbird
import MLXLMCommon

/// One listener and retained generation ownership. The session has no fixed
/// lifetime and no request count, so there is no rotation: the loaded model
/// stays resident and serving until the server is stopped or the session fails.
public actor DistributedLocalServer {
    var generation: DistributedLocalServerGeneration
    let binding: DistributedLocalSessionBinding
    let config: LocalInferenceHTTPConfig
    let defaultMaxTokens: Int
    let firstTokenBudgetPolicy: DistributedFirstTokenBudgetPolicy?
    let tokenizerLoader: @Sendable (URL) async throws -> TokenizerHandle
    let discovery: DistributedLocalDiscovery?
    /// Incident log and pair telemetry (S24); nil records nothing (tests).
    let observability: ClusterObservability?
    let responseRouter = DistributedHTTPResponseRouter()
    var phase: DistributedLocalServerPhase = .prepared
    var boundPort: UInt16?
    var ownDiscovery: LocalEndpoint.Info?
    var failed = false
    var startupTask: Task<Void, Error>?
    var serviceTask: Task<Void, Never>?
    var monitorTask: Task<Void, Never>?
    var teardownTask: Task<Void, Never>?
    var stopWaiters: [CheckedContinuation<DistributedLocalServerStatus, Never>] = []
    /// Requests waiting for the pipeline, oldest first (`DistributedRequestQueue`).
    var waiting: [UUID] = []
    /// How many may wait, fixed when the server is made.
    nonisolated let queue: DistributedRequestQueue.Limits

    // Existing test/read-only host views refer to the retained current generation.
    var session: any DistributedLocalServerSession { generation.session }
    var entry: MultiModelBatchSchedulerEngine.ModelRegistryEntry? { generation.entry }
    var pins: Set<UUID> { generation.pins }
    var responses: DistributedHTTPResponses { generation.responses }

    public init(session: DistributedInstalledSession, config: LocalInferenceHTTPConfig,
                firstTokenBudgetPolicy: DistributedFirstTokenBudgetPolicy? = nil,
                publishDiscovery: Bool = true, observability: ClusterObservability? = .current()) {
        // The waiting depth from the owner's environment (`DARKBLOOM_CLUSTER_QUEUE_WAITING`).
        let queue = DistributedRequestQueue.Limits.fromEnvironment()
        generation = .init(session: session, responseLimit: queue.responseLimit); binding = .init(session)
        self.queue = queue
        self.config = config
        defaultMaxTokens = min(DistributedEngineFactory.defaultOutputTokens, session.profile.maxOutputTokens)
        self.firstTokenBudgetPolicy = firstTokenBudgetPolicy
        tokenizerLoader = { TokenizerHandle(try await LocalTokenizerLoader().load(from: $0)) }
        discovery = publishDiscovery ? .local : nil
        self.observability = observability
    }

    init(session: any DistributedLocalServerSession, config: LocalInferenceHTTPConfig,
         firstTokenBudgetPolicy: DistributedFirstTokenBudgetPolicy? = nil,
         tokenizerLoader: @escaping @Sendable (URL) async throws -> TokenizerHandle,
         discovery: DistributedLocalDiscovery? = nil, observability: ClusterObservability? = nil,
         queue: DistributedRequestQueue.Limits = .standard) {
        generation = .init(session: session, responseLimit: queue.responseLimit); binding = .init(session)
        self.queue = queue
        self.config = config
        defaultMaxTokens = min(DistributedEngineFactory.defaultOutputTokens, session.profile.maxOutputTokens)
        self.firstTokenBudgetPolicy = firstTokenBudgetPolicy
        self.tokenizerLoader = tokenizerLoader; self.discovery = discovery
        self.observability = observability
    }

    public var status: DistributedLocalServerStatus {
        .init(phase: phase, publicModelID: binding.publicModelID,
              boundPort: boundPort, acquisitions: generation.pins.count,
              session: generation.session.status, failed: failed)
    }

    /// Returns after the actual listener bind callback. Startup failure retains
    /// its exact generation until the existing owner cleanup barriers finish.
    public func start(bindTimeout: Duration = .seconds(5)) async throws {
        guard phase == .prepared else { throw DistributedLocalServerError.alreadyStarted }
        guard bindTimeout > .zero, bindTimeout <= .seconds(60) else {
            throw DistributedLocalServerError.bindTimedOut
        }
        phase = .starting
        let target = generation
        let task = Task { try await self.prepareAndBind(target, timeout: bindTimeout) }
        startupTask = task
        do {
            try await withTaskCancellationHandler { try await task.value; try Task.checkCancellation() }
                onCancel: { Task { await self.beginTeardown(drainUntil: nil) } }
        } catch {
            failed = true
            recordLaunchFailure(error, target: target)
            beginTeardown(drainUntil: nil); throw error
        }
    }

    /// Every launch failure becomes one incident with a classified reason (S24).
    func recordLaunchFailure(_ error: Error, target: DistributedLocalServerGeneration) {
        guard let observability else { return }
        let interrupted = error is CancellationError || (error as? DistributedLocalServerError) == .startupInterrupted
        observability.recordFailure(interrupted ? .activationRejected : .activationLaunchFailed, source: "leader",
            error: Self.describe(error), facts: target.session.httpObservabilityFacts, severity: interrupted ? .warn : .error)
    }

    /// A serving session that ended without being asked to (S24).
    func recordSessionFailure(_ target: DistributedLocalServerGeneration) {
        guard let observability else { return }
        let facts = target.session.httpObservabilityFacts
        let lost = !(facts?.terminations.isEmpty ?? true)
        observability.recordFailure(lost ? .peerLost : .sessionFailed, source: "leader",
            error: "The serving session stopped without being asked to (session \(target.session.status.rawValue))"
                + (facts?.terminations.first.map { "; " + $0 } ?? ""), facts: facts)
    }

    /// A stop that could not prove every owner released its device (S24).
    func recordCleanupUnresolved(_ target: DistributedLocalServerGeneration) {
        guard let observability else { return }
        observability.recordFailure(.cleanupUnresolved, source: "leader",
            error: "Distributed cleanup is unresolved (session \(target.session.status.rawValue)); ownership cannot be resolved yet"
                + (target.session.httpStopDetail.map { "; " + $0 } ?? ""),
            facts: target.session.httpObservabilityFacts, severity: .warn)
    }

    static func describe(_ error: Error) -> String {
        let text = String(describing: error)
        let type = String(describing: Swift.type(of: error))
        return text.contains(type) ? text : "\(type): \(text)"
    }

    func listenerExited() {
        boundPort = nil
        if teardownTask == nil { failed = true; beginTeardown(drainUntil: nil) }
    }

    public func stop(until deadline: UInt64) async -> DistributedLocalServerStatus {
        beginTeardown(drainUntil: nil)
        return await waitForTeardown(until: deadline)
    }

    public func drain(until deadline: UInt64) async -> DistributedLocalServerStatus {
        beginTeardown(drainUntil: deadline)
        return await waitForTeardown(until: deadline)
    }

    private func waitForTeardown(until deadline: UInt64) async -> DistributedLocalServerStatus {
        while teardownTask != nil, DispatchTime.now().uptimeNanoseconds < deadline {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
        }
        if teardownTask != nil { phase = .quarantined; publishStopOutcome() }
        return status
    }

    /// Explicit quarantine may be returned before cleanup; the host retains all
    /// pending generation work and must not be discarded as an empty slot.
    public func waitUntilStopped() async -> DistributedLocalServerStatus {
        if [.prepared, .stopped, .quarantined].contains(phase) { return status }
        return await withCheckedContinuation { stopWaiters.append($0) }
    }

    func publishStopOutcome() {
        let result = status, waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: result) }
    }

    func removeDiscovery() {
        if let ownDiscovery { discovery?.removeIfOwned(ownDiscovery); self.ownDiscovery = nil }
    }
}
