import Foundation
import Hummingbird
import MLXLMCommon

/// One listener and retained generation ownership. A replacement factory enables
/// quota rotation only; fixed-lifetime expiry still stops this first increment.
public actor DistributedLocalServer {
    typealias ReplacementFactory = @Sendable () async throws -> any DistributedLocalServerSession
    var generation: DistributedLocalServerGeneration
    var seenMembershipEpochs: Set<UUID>
    let binding: DistributedLocalSessionBinding
    let replacementSessionFactory: ReplacementFactory?
    let config: LocalInferenceHTTPConfig
    let defaultMaxTokens: Int
    let firstTokenBudgetPolicy: DistributedFirstTokenBudgetPolicy?
    let tokenizerLoader: @Sendable (URL) async throws -> TokenizerHandle
    let discovery: DistributedLocalDiscovery?
    let responseRouter = DistributedHTTPResponseRouter()
    var phase: DistributedLocalServerPhase = .prepared
    var boundPort: UInt16?
    var ownDiscovery: LocalEndpoint.Info?
    var failed = false
    var startupTask: Task<Void, Error>?
    var rotationTask: Task<Void, Never>?
    var serviceTask: Task<Void, Never>?
    var lifetimeTask: Task<Void, Never>?
    var teardownTask: Task<Void, Never>?
    var stopWaiters: [CheckedContinuation<DistributedLocalServerStatus, Never>] = []

    // Existing test/read-only host views refer to the retained current generation.
    var session: any DistributedLocalServerSession { generation.session }
    var entry: MultiModelBatchSchedulerEngine.ModelRegistryEntry? { generation.entry }
    var pin: UUID? { generation.pin }
    var responses: DistributedHTTPResponses { generation.responses }

    public init(session: DistributedInstalledSession, config: LocalInferenceHTTPConfig,
                firstTokenBudgetPolicy: DistributedFirstTokenBudgetPolicy? = nil,
                publishDiscovery: Bool = true,
                replacementSessionFactory: (@Sendable () async throws -> DistributedInstalledSession)? = nil) {
        generation = .init(session: session); binding = .init(session)
        seenMembershipEpochs = [session.expectedIdentity.membershipEpoch]
        self.config = config; defaultMaxTokens = session.profile.maxOutputTokens
        self.firstTokenBudgetPolicy = firstTokenBudgetPolicy
        tokenizerLoader = { TokenizerHandle(try await LocalTokenizerLoader().load(from: $0)) }
        discovery = publishDiscovery ? .local : nil
        if let factory = replacementSessionFactory {
            self.replacementSessionFactory = { try await factory() }
        } else { self.replacementSessionFactory = nil }
    }

    init(session: any DistributedLocalServerSession, config: LocalInferenceHTTPConfig,
         firstTokenBudgetPolicy: DistributedFirstTokenBudgetPolicy? = nil,
         tokenizerLoader: @escaping @Sendable (URL) async throws -> TokenizerHandle,
         discovery: DistributedLocalDiscovery? = nil,
         replacementSessionFactory: ReplacementFactory? = nil) {
        generation = .init(session: session); binding = .init(session)
        seenMembershipEpochs = [session.expectedIdentity.membershipEpoch]
        self.config = config; defaultMaxTokens = session.profile.maxOutputTokens
        self.firstTokenBudgetPolicy = firstTokenBudgetPolicy
        self.tokenizerLoader = tokenizerLoader; self.discovery = discovery
        self.replacementSessionFactory = replacementSessionFactory
    }

    public var status: DistributedLocalServerStatus {
        .init(phase: phase, publicModelID: binding.publicModelID,
              boundPort: boundPort, acquisitions: generation.pin == nil ? 0 : 1,
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
            failed = true; beginTeardown(drainUntil: nil); throw error
        }
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
