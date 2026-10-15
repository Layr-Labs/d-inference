import Foundation
import Hummingbird
import MLXLMCommon

/// One installed cluster session served by the normal local OpenAI HTTP stack.
/// The caller retains this host, including on start failure or quarantine, until
/// cleanupComplete. No local model container, device gate, or new epoch is made.
public actor DistributedLocalServer {
    let session: any DistributedLocalServerSession
    let config: LocalInferenceHTTPConfig
    let firstTokenBudgetPolicy: DistributedFirstTokenBudgetPolicy?
    let tokenizerLoader: @Sendable (URL) async throws -> TokenizerHandle
    let discovery: DistributedLocalDiscovery?
    var phase: DistributedLocalServerPhase = .prepared
    var entry: MultiModelBatchSchedulerEngine.ModelRegistryEntry?
    var pin: UUID?
    var boundPort: UInt16?
    var ownDiscovery: LocalEndpoint.Info?
    var failed = false
    var startupTask: Task<Void, Error>?
    var serviceTask: Task<Void, Never>?
    var lifetimeTask: Task<Void, Never>?
    var teardownTask: Task<Void, Never>?
    var stopWaiters: [CheckedContinuation<DistributedLocalServerStatus, Never>] = []
    var pinWaiters: [CheckedContinuation<Void, Never>] = []

    public init(session: DistributedInstalledSession, config: LocalInferenceHTTPConfig,
                firstTokenBudgetPolicy: DistributedFirstTokenBudgetPolicy? = nil,
                publishDiscovery: Bool = true) {
        self.session = session; self.config = config
        self.firstTokenBudgetPolicy = firstTokenBudgetPolicy
        tokenizerLoader = { TokenizerHandle(try await LocalTokenizerLoader().load(from: $0)) }
        discovery = publishDiscovery ? .local : nil
    }

    init(session: any DistributedLocalServerSession, config: LocalInferenceHTTPConfig,
         firstTokenBudgetPolicy: DistributedFirstTokenBudgetPolicy? = nil,
         tokenizerLoader: @escaping @Sendable (URL) async throws -> TokenizerHandle,
         discovery: DistributedLocalDiscovery? = nil) {
        self.session = session; self.config = config
        self.firstTokenBudgetPolicy = firstTokenBudgetPolicy
        self.tokenizerLoader = tokenizerLoader; self.discovery = discovery
    }

    public var status: DistributedLocalServerStatus {
        .init(phase: phase, publicModelID: session.model.publicModelID,
              boundPort: boundPort, acquisitions: pin == nil ? 0 : 1,
              session: session.status, failed: failed)
    }

    /// Returns only after this application's bind callback, not a TCP/HTTP probe.
    /// Failure starts retained teardown; it does not erase a partially started owner.
    public func start(bindTimeout: Duration = .seconds(5)) async throws {
        guard phase == .prepared else { throw DistributedLocalServerError.alreadyStarted }
        guard bindTimeout > .zero, bindTimeout <= .seconds(60) else {
            throw DistributedLocalServerError.bindTimedOut
        }
        phase = .starting
        let task = Task { try await self.prepareAndBind(timeout: bindTimeout) }
        startupTask = task
        do {
            try await withTaskCancellationHandler { try await task.value; try Task.checkCancellation() }
                onCancel: { Task { await self.beginTeardown(drainUntil: nil) } }
        } catch {
            failed = true
            beginTeardown(drainUntil: nil)
            throw error
        }
    }

    private func prepareAndBind(timeout: Duration) async throws {
        try requireStarting()
        try session.validateModelInputs()
        let tokenizer = try await tokenizerLoader(session.model.directory)
        try session.validateModelInputs()
        try requireStarting()
        let eos = try session.model.stopTokenIDs(tokenizerEOS: tokenizer.inner.eosTokenId)
        // Reject an invalid optional policy before starting either native owner.
        try firstTokenBudgetPolicy?.validate(maximumPromptTokens: session.profile.maxPromptTokens)
        try await session.start()
        try requireStarting()
        guard let lifetime = session.lifetimeDeadlineUptimeNanoseconds,
              lifetime > DispatchTime.now().uptimeNanoseconds else {
            throw DistributedLocalServerError.lifetimeExpired
        }
        entry = try DistributedEngineFactory.makeRegistryEntry(
            owner: session, expectedIdentity: session.expectedIdentity,
            publicModelID: session.model.publicModelID, profile: session.profile,
            tokenizer: tokenizer, eosTokenIDs: eos, modelType: session.model.modelType,
            firstTokenBudgetPolicy: firstTokenBudgetPolicy)
        startLifetimeMonitor(deadline: lifetime)
        let application = makeApplication()
        serviceTask = Task {
            do { try await application.runService(gracefulShutdownSignals: []) }
            catch is CancellationError {} catch { self.failed = true }
            self.listenerExited()
        }
        let end = ContinuousClock.now.advanced(by: timeout)
        while phase == .starting, ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(10))
        }
        if phase == .serving { return }
        try Task.checkCancellation()
        throw phase == .starting ? DistributedLocalServerError.bindTimedOut : DistributedLocalServerError.bindFailed
    }

    private func requireStarting() throws {
        try Task.checkCancellation()
        guard phase == .starting else { throw DistributedLocalServerError.startupInterrupted }
    }

    func listenerExited() {
        boundPort = nil
        if teardownTask == nil { failed = true; beginTeardown(drainUntil: nil) }
    }

    /// Bounds only this caller's wait. Missing proof keeps all ownership here.
    public func stop(until deadline: UInt64) async -> DistributedLocalServerStatus {
        beginTeardown(drainUntil: nil)
        return await waitForTeardown(until: deadline)
    }

    /// New HTTP acquisitions close first. The installed owner drains its current
    /// explicit request release; expiration/escalation switches to cancellation.
    public func drain(until deadline: UInt64) async -> DistributedLocalServerStatus {
        beginTeardown(drainUntil: deadline)
        return await waitForTeardown(until: deadline)
    }

    private func waitForTeardown(until deadline: UInt64) async -> DistributedLocalServerStatus {
        while teardownTask != nil, DispatchTime.now().uptimeNanoseconds < deadline {
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { break }
        }
        if teardownTask != nil {
            phase = .quarantined
            publishStopOutcome()
        }
        return status
    }

    /// Returns completed listener/pin/owner teardown OR an explicit bounded-stop
    /// quarantine. The latter retains the in-flight teardown and all ownership;
    /// callers can observe status for eventual cleanup and must not rotate.
    public func waitUntilStopped() async -> DistributedLocalServerStatus {
        if [.prepared, .stopped, .quarantined].contains(phase) {
            return status
        }
        return await withCheckedContinuation { stopWaiters.append($0) }
    }

    func beginTeardown(drainUntil: UInt64?) {
        if phase == .stopped { return }
        removeDiscovery()
        if teardownTask != nil {
            // Explicit stop or fixed lifetime expiry interrupts a graceful drain.
            if drainUntil == nil {
                if phase != .quarantined { phase = .stopping }
                serviceTask?.cancel()
                Task { _ = await session.stop(until: DispatchTime.now().uptimeNanoseconds) }
            }
            return
        }
        if phase != .quarantined { phase = drainUntil == nil ? .stopping : .draining }
        startupTask?.cancel()
        if drainUntil == nil { serviceTask?.cancel() }
        teardownTask = Task { await self.finishTeardown(drainUntil: drainUntil) }
    }

    private func finishTeardown(drainUntil: UInt64?) async {
        // Joining startup prevents a late tokenizer/load/bridge installation.
        _ = await startupTask?.result
        if let drainUntil { _ = await session.drain(until: drainUntil) }
        serviceTask?.cancel()
        // Engine cancellation/retirement must run while HTTP streams unwind;
        // awaiting the listener first can deadlock a stream waiting on the owner.
        let bridge = entry?.engineV2Bridge
        let engineStop = Task { await bridge?.shutdown() }
        await session.shutdown()
        _ = await engineStop.value
        _ = await serviceTask?.value
        if pin != nil { await withCheckedContinuation { pinWaiters.append($0) } }
        lifetimeTask?.cancel(); lifetimeTask = nil
        removeDiscovery()
        boundPort = nil; serviceTask = nil; startupTask = nil
        if session.status == .released {
            entry = nil; phase = .stopped
        } else {
            // Keep tokenizer, bridge and session on an unresolved owner release.
            phase = .quarantined
        }
        teardownTask = nil
        publishStopOutcome()
    }

    private func publishStopOutcome() {
        let result = status, waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: result) }
    }

    private func startLifetimeMonitor(deadline: UInt64) {
        lifetimeTask = Task {
            while !Task.isCancelled {
                let now = DispatchTime.now().uptimeNanoseconds
                if now >= deadline {
                    beginTeardown(drainUntil: nil); return
                }
                // A queued session invalidation callback may not yet have
                // changed status. Pair invalidity is independently abnormal.
                if [.starting, .serving].contains(phase),
                   session.status != .ready || session.httpSessionInvalid {
                    failed = true
                    beginTeardown(drainUntil: nil); return
                }
                if ![.starting, .serving].contains(phase), [.quarantined, .released].contains(session.status) {
                    beginTeardown(drainUntil: nil); return
                }
                if phase == .serving, pin == nil, session.httpSessionExhausted {
                    beginTeardown(drainUntil: nil); return
                }
                do { try await Task.sleep(nanoseconds: min(deadline - now, 100_000_000)) }
                catch { return }
            }
        }
    }

    func removeDiscovery() {
        if let ownDiscovery { discovery?.removeIfOwned(ownDiscovery); self.ownDiscovery = nil }
    }
}
