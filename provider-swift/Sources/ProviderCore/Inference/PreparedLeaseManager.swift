// Copyright © 2026 Eigen Labs.
//
// Actor-serialized lifecycle for prepared inference leases. Every public
// transition carries the complete AttemptIdentity; the lease UUID is only an
// index and never sufficient authorization for a duplicate or control.

import Foundation

private actor PreparedTerminalWaitRace {
    private var result: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func wait() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func resolve(_ value: Bool) {
        guard result == nil else { return }
        result = value
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: value)
        }
    }
}

private enum PreparedTerminalWait {
    static func run(
        timeout: Duration,
        operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let race = PreparedTerminalWaitRace()
        let operationTask = Task {
            await operation()
            await race.resolve(true)
        }
        let timeoutTask = Task {
            do {
                try await ContinuousClock().sleep(for: timeout)
                await race.resolve(false)
            } catch {}
        }
        let completed = await race.wait()
        if completed {
            timeoutTask.cancel()
        } else {
            operationTask.cancel()
        }
        return completed
    }
}

public actor PreparedLeaseManager {
    public typealias Now = @Sendable () -> Date

    private typealias PrepareWaiter = CheckedContinuation<PreparedLease, Error>
    private typealias StartWaiter = CheckedContinuation<PreparedLeaseStartResult, Error>
    private typealias ControlWaiter = CheckedContinuation<PreparedLeaseControlResult, Never>

    private enum PendingStop: Sendable {
        case abort
        case cancel
        case expire

        var terminalState: PreparedLeaseState {
            switch self {
            case .abort: return .aborted
            case .cancel: return .cancelled
            case .expire: return .expired
            }
        }

        var controlResult: PreparedLeaseControlResult {
            switch self {
            case .abort: return .aborted
            case .cancel: return .cancelled
            case .expire: return .expired
            }
        }

        var error: PreparedLeaseError {
            switch self {
            case .abort: return .aborted
            case .cancel: return .cancelled
            case .expire: return .expired
            }
        }
    }

    private struct Binding: Sendable {
        let identity: AttemptIdentity
        let requestDigest: String?
        let modelID: String?

        init(inference: PreparedInference) {
            identity = inference.identity
            requestDigest = inference.requestDigest
            modelID = inference.modelID
        }

        init(lease: PreparedLease) {
            identity = lease.identity
            requestDigest = lease.requestDigest
            modelID = lease.modelID
        }

        init(identity: AttemptIdentity) {
            self.identity = identity
            requestDigest = nil
            modelID = nil
        }

        func matches(_ inference: PreparedInference) -> Bool {
            identity == inference.identity
                && (requestDigest == nil || requestDigest == inference.requestDigest)
                && (modelID == nil || modelID == inference.modelID)
        }
    }

    private struct Preparing {
        let inference: PreparedInference
        let executor: any PreparedInferenceExecutor
        let expiresAt: Date
        var prepareWaiters: [PrepareWaiter] = []
        var controlWaiters: [ControlWaiter] = []
        var pendingStop: PendingStop?
    }

    private struct Reserved {
        let lease: PreparedLease
        let inference: PreparedInference
        let executor: any PreparedInferenceExecutor
    }

    private struct Starting {
        let reserved: Reserved
        var startWaiters: [StartWaiter] = []
        var controlWaiters: [ControlWaiter] = []
        var pendingStop: PendingStop?
    }

    private struct Started {
        let lease: PreparedLease
        let executor: any PreparedInferenceExecutor
        let execution: PreparedInferenceExecution
    }

    private struct Aborting {
        let binding: Binding
        var waiters: [ControlWaiter] = []
        let terminalState: PreparedLeaseState
        let result: PreparedLeaseControlResult
    }

    private struct Cancelling {
        let started: Started
        var waiters: [ControlWaiter] = []
    }

    private struct Tombstone {
        let binding: Binding
        let state: PreparedLeaseState
        let createdAt: Date
    }

    private enum Entry {
        case preparing(Preparing)
        case reserved(Reserved)
        case starting(Starting)
        case started(Started)
        case aborting(Aborting)
        case cancelling(Cancelling)
        case terminal(Tombstone)

        var state: PreparedLeaseState {
            switch self {
            case .preparing: return .preparing
            case .reserved: return .reserved
            case .starting: return .starting
            case .started: return .started
            case .aborting: return .aborting
            case .cancelling: return .cancelling
            case .terminal(let tombstone): return tombstone.state
            }
        }

        var binding: Binding {
            switch self {
            case .preparing(let value): return Binding(inference: value.inference)
            case .reserved(let value): return Binding(lease: value.lease)
            case .starting(let value): return Binding(lease: value.reserved.lease)
            case .started(let value): return Binding(lease: value.lease)
            case .aborting(let value): return value.binding
            case .cancelling(let value): return Binding(lease: value.started.lease)
            case .terminal(let value): return value.binding
            }
        }
    }

    private var entries: [LeaseID: Entry] = [:]
    private var expiryTasks: [LeaseID: Task<Void, Never>] = [:]
    private let now: Now
    private let automaticallyExpire: Bool
    private let tombstoneRetention: TimeInterval
    private let maxTombstones: Int
    private let terminalWaitTimeout: Duration

    public init(
        now: @escaping Now = { Date() },
        automaticallyExpire: Bool = true,
        tombstoneRetention: TimeInterval = 300,
        maxTombstones: Int = 4_096,
        terminalWaitTimeout: Duration = .seconds(5)
    ) {
        self.now = now
        self.automaticallyExpire = automaticallyExpire
        self.tombstoneRetention = max(1, tombstoneRetention)
        self.maxTombstones = max(1, maxTombstones)
        self.terminalWaitTimeout = max(.zero, terminalWaitTimeout)
    }

    deinit {
        for task in expiryTasks.values {
            task.cancel()
        }
    }

    // MARK: - Prepare

    public func prepare(
        inference: PreparedInference,
        expiresAt: Date,
        using executor: any PreparedInferenceExecutor
    ) async throws -> PreparedLease {
        let identity = inference.identity
        let leaseID = identity.leaseID
        pruneTombstones(at: now())

        if let existing = entries[leaseID] {
            return try await duplicatePrepare(existing, inference: inference)
        }

        let preparedAt = now()
        guard expiresAt > preparedAt else {
            entries[leaseID] = .terminal(
                Tombstone(
                    binding: Binding(inference: inference),
                    state: .expired,
                    createdAt: preparedAt))
            await inference.resourceRelease.fire()
            throw PreparedLeaseError.alreadyExpired
        }

        entries[leaseID] = .preparing(
            Preparing(
                inference: inference,
                executor: executor,
                expiresAt: expiresAt))
        scheduleExpiry(identity: identity, expiresAt: expiresAt)

        let admission: PreparedInferenceAdmission
        do {
            admission = try await executor.prepareInference(inference, expiresAt: expiresAt)
        } catch {
            cancelExpiryTask(leaseID: leaseID)
            let pending = takePreparing(identity: identity)
            let stop = pending?.pendingStop
            let terminalError: Error = stop?.error ?? error
            entries[leaseID] = .terminal(
                Tombstone(
                    binding: Binding(inference: inference),
                    state: stop?.terminalState ?? .failed,
                    createdAt: now()))
            await inference.resourceRelease.fire()
            resumePrepareWaiters(pending?.prepareWaiters ?? [], throwing: terminalError)
            resumeControlWaiters(
                pending?.controlWaiters ?? [],
                with: stop?.controlResult ?? .failed)
            throw terminalError
        }

        guard let pending = takePreparing(identity: identity) else {
            cancelExpiryTask(leaseID: leaseID)
            _ = await stopExecutor(identity: identity, executor: executor, cancel: false)
            await inference.resourceRelease.fire()
            throw PreparedLeaseError.failed("prepare state disappeared")
        }

        let admittedAt = now()
        if let stop = pending.pendingStop
            ?? (expiresAt <= admittedAt ? PendingStop.expire : nil)
        {
            cancelExpiryTask(leaseID: leaseID)
            entries[leaseID] = .aborting(
                Aborting(
                    binding: Binding(inference: inference),
                    waiters: pending.controlWaiters,
                    terminalState: stop.terminalState,
                    result: stop.controlResult))
            let stopped = await stopExecutor(
                identity: identity, executor: executor, cancel: false)
            await inference.resourceRelease.fire()
            let state: PreparedLeaseState = stopped ? stop.terminalState : .failed
            let result: PreparedLeaseControlResult = stopped ? stop.controlResult : .failed
            let error: PreparedLeaseError =
                stopped
                ? stop.error : .failed("prepared inference terminal wait timed out")
            let controlWaiters = takeAbortingWaiters(identity: identity)
            entries[leaseID] = .terminal(
                Tombstone(
                    binding: Binding(inference: inference),
                    state: state,
                    createdAt: now()))
            resumePrepareWaiters(pending.prepareWaiters, throwing: error)
            resumeControlWaiters(controlWaiters, with: result)
            throw error
        }

        let lease = PreparedLease(
            inference: inference,
            expiresAt: expiresAt,
            now: admittedAt,
            admission: admission)
        entries[leaseID] = .reserved(
            Reserved(
                lease: lease, inference: inference, executor: executor))
        resumePrepareWaiters(pending.prepareWaiters, returning: lease)
        return lease
    }

    private func duplicatePrepare(
        _ existing: Entry,
        inference: PreparedInference
    ) async throws -> PreparedLease {
        guard existing.binding.identity == inference.identity else {
            await inference.resourceRelease.fire()
            throw PreparedLeaseError.identityConflict
        }
        guard existing.binding.matches(inference) else {
            await inference.resourceRelease.fire()
            throw PreparedLeaseError.conflictingDuplicate
        }

        let leaseID = inference.identity.leaseID
        // A duplicate may have independently acquired the same model pin.
        // Its release is part of duplicate quiescence, not fire-and-forget.
        await inference.resourceRelease.fire()
        guard let current = entries[leaseID],
            current.binding.identity == inference.identity
        else {
            throw PreparedLeaseError.failed("duplicate prepare state disappeared")
        }
        guard current.binding.matches(inference) else {
            throw PreparedLeaseError.conflictingDuplicate
        }

        switch current {
        case .preparing(var pending):
            return try await withCheckedThrowingContinuation { continuation in
                pending.prepareWaiters.append(continuation)
                entries[leaseID] = .preparing(pending)
            }
        case .reserved(let reserved):
            return reserved.lease
        case .starting(let starting):
            return starting.reserved.lease
        case .started(let started):
            return started.lease
        case .aborting(let aborting):
            throw error(for: aborting.terminalState)
        case .cancelling:
            throw PreparedLeaseError.cancelled
        case .terminal(let tombstone):
            throw error(for: tombstone.state)
        }
    }

    // MARK: - Start

    public func start(identity: AttemptIdentity) async throws -> PreparedLeaseStartResult {
        pruneTombstones(at: now())
        let leaseID = identity.leaseID
        guard let entry = entries[leaseID] else {
            throw PreparedLeaseError.unknownLease
        }
        guard entry.binding.identity == identity else {
            throw PreparedLeaseError.identityConflict
        }

        switch entry {
        case .preparing:
            throw PreparedLeaseError.notReady
        case .reserved(let reserved):
            if reserved.lease.expiresAt <= now() {
                await expireReserved(reserved)
                throw PreparedLeaseError.expired
            }
            cancelExpiryTask(leaseID: leaseID)
            entries[leaseID] = .starting(Starting(reserved: reserved))
            return try await performStart(reserved)
        case .starting(var starting):
            return try await withCheckedThrowingContinuation { continuation in
                starting.startWaiters.append(continuation)
                entries[leaseID] = .starting(starting)
            }
        case .started:
            return .alreadyStarted
        case .aborting(let aborting):
            throw error(for: aborting.terminalState)
        case .cancelling:
            throw PreparedLeaseError.cancelled
        case .terminal(let tombstone):
            throw error(for: tombstone.state)
        }
    }

    private func performStart(_ reserved: Reserved) async throws -> PreparedLeaseStartResult {
        let identity = reserved.lease.identity
        let leaseID = identity.leaseID
        let execution: PreparedInferenceExecution
        do {
            execution = try await reserved.executor.startPreparedInference(identity: identity)
        } catch {
            guard let starting = takeStarting(identity: identity) else {
                await reserved.inference.resourceRelease.fire()
                throw PreparedLeaseError.failed("start state disappeared")
            }
            let stop = starting.pendingStop
            entries[leaseID] = .aborting(
                Aborting(
                    binding: Binding(lease: reserved.lease),
                    waiters: starting.controlWaiters,
                    terminalState: stop?.terminalState ?? .failed,
                    result: stop?.controlResult ?? .failed))
            let stopped = await stopExecutor(
                identity: identity, executor: reserved.executor, cancel: false)
            await reserved.inference.resourceRelease.fire()
            let terminalState: PreparedLeaseState =
                stopped ? (stop?.terminalState ?? .failed) : .failed
            let terminalError: Error =
                !stopped
                ? PreparedLeaseError.failed("prepared inference terminal wait timed out")
                : (stop?.error ?? error)
            let terminalResult: PreparedLeaseControlResult =
                stopped ? (stop?.controlResult ?? .failed) : .failed
            let controlWaiters = takeAbortingWaiters(identity: identity)
            entries[leaseID] = .terminal(
                Tombstone(
                    binding: Binding(lease: reserved.lease),
                    state: terminalState,
                    createdAt: now()))
            resumeStartWaiters(starting.startWaiters, throwing: terminalError)
            resumeControlWaiters(controlWaiters, with: terminalResult)
            throw terminalError
        }

        guard let starting = takeStarting(identity: identity) else {
            _ = await stopExecutor(
                identity: identity,
                executor: reserved.executor,
                cancel: true,
                completion: execution.completion)
            throw PreparedLeaseError.failed("start state disappeared")
        }

        let started = Started(
            lease: reserved.lease,
            executor: reserved.executor,
            execution: execution)
        resumeStartWaiters(starting.startWaiters, returning: .alreadyStarted)

        if starting.pendingStop != nil {
            entries[leaseID] = .cancelling(
                Cancelling(
                    started: started,
                    waiters: starting.controlWaiters))
            let stopped = await stopExecutor(
                identity: identity,
                executor: reserved.executor,
                cancel: true,
                completion: execution.completion)
            let controlWaiters = takeCancellingWaiters(identity: identity)
            entries[leaseID] = .terminal(
                Tombstone(
                    binding: Binding(lease: reserved.lease),
                    state: stopped ? .cancelled : .failed,
                    createdAt: now()))
            resumeControlWaiters(controlWaiters, with: stopped ? .cancelled : .failed)
        } else {
            entries[leaseID] = .started(started)
            observeCompletion(started)
        }
        return .started(execution)
    }

    // MARK: - Abort / cancel

    public func abort(identity: AttemptIdentity) async -> PreparedLeaseControlResult {
        await control(identity: identity, requested: .abort)
    }

    public func cancel(identity: AttemptIdentity) async -> PreparedLeaseControlResult {
        await control(identity: identity, requested: .cancel)
    }

    private func control(
        identity: AttemptIdentity,
        requested: PendingStop
    ) async -> PreparedLeaseControlResult {
        pruneTombstones(at: now())
        let leaseID = identity.leaseID
        guard let entry = entries[leaseID] else {
            entries[leaseID] = .terminal(
                Tombstone(
                    binding: Binding(identity: identity),
                    state: requested.terminalState,
                    createdAt: now()))
            return requested.controlResult
        }
        guard entry.binding.identity == identity else {
            return .identityConflict
        }

        switch entry {
        case .preparing(var preparing):
            return await withCheckedContinuation { continuation in
                if preparing.pendingStop == nil {
                    preparing.pendingStop = requested
                }
                preparing.controlWaiters.append(continuation)
                entries[leaseID] = .preparing(preparing)
                schedulePendingControlTimeout(identity: identity)
            }
        case .reserved(let reserved):
            cancelExpiryTask(leaseID: leaseID)
            entries[leaseID] = .aborting(
                Aborting(
                    binding: Binding(lease: reserved.lease),
                    terminalState: requested.terminalState,
                    result: requested.controlResult))
            let stopped = await stopExecutor(
                identity: identity, executor: reserved.executor, cancel: false)
            await reserved.inference.resourceRelease.fire()
            let duplicateWaiters = takeAbortingWaiters(identity: identity)
            entries[leaseID] = .terminal(
                Tombstone(
                    binding: Binding(lease: reserved.lease),
                    state: stopped ? requested.terminalState : .failed,
                    createdAt: now()))
            let result: PreparedLeaseControlResult =
                stopped ? requested.controlResult : .failed
            resumeControlWaiters(duplicateWaiters, with: result)
            return result
        case .starting(var starting):
            return await withCheckedContinuation { continuation in
                starting.pendingStop = .cancel
                starting.controlWaiters.append(continuation)
                entries[leaseID] = .starting(starting)
                schedulePendingControlTimeout(identity: identity)
            }
        case .started(let started):
            entries[leaseID] = .cancelling(Cancelling(started: started))
            let stopped = await stopExecutor(
                identity: identity,
                executor: started.executor,
                cancel: true,
                completion: started.execution.completion)
            let duplicateWaiters = takeCancellingWaiters(identity: identity)
            entries[leaseID] = .terminal(
                Tombstone(
                    binding: Binding(lease: started.lease),
                    state: stopped ? .cancelled : .failed,
                    createdAt: now()))
            let result: PreparedLeaseControlResult = stopped ? .cancelled : .failed
            resumeControlWaiters(duplicateWaiters, with: result)
            return result
        case .aborting(var aborting):
            return await withCheckedContinuation { continuation in
                aborting.waiters.append(continuation)
                entries[leaseID] = .aborting(aborting)
            }
        case .cancelling(var cancelling):
            return await withCheckedContinuation { continuation in
                cancelling.waiters.append(continuation)
                entries[leaseID] = .cancelling(cancelling)
            }
        case .terminal(let tombstone):
            switch tombstone.state {
            case .aborted: return .alreadyAborted
            case .cancelled, .completed: return .alreadyCancelled
            case .expired: return .expired
            case .failed: return .failed
            default: return requested.controlResult
            }
        }
    }

    private func stopExecutor(
        identity: AttemptIdentity,
        executor: any PreparedInferenceExecutor,
        cancel: Bool,
        completion: PreparedInferenceCompletion? = nil
    ) async -> Bool {
        let completed = await PreparedTerminalWait.run(timeout: terminalWaitTimeout) {
            if cancel {
                await executor.cancelPreparedInference(identity: identity)
            } else {
                await executor.abortPreparedInference(identity: identity)
            }
            if let completion {
                await completion.wait()
            }
        }
        if !completed {
            await executor.forceReleasePreparedInference(identity: identity)
        }
        return completed
    }

    private func schedulePendingControlTimeout(identity: AttemptIdentity) {
        let timeout = terminalWaitTimeout
        Task { [weak self] in
            do {
                try await ContinuousClock().sleep(for: timeout)
            } catch {
                return
            }
            await self?.failPendingControl(identity: identity)
        }
    }

    private func failPendingControl(identity: AttemptIdentity) async {
        let leaseID = identity.leaseID
        let timeoutError = PreparedLeaseError.failed(
            "prepared inference terminal wait timed out")
        switch entries[leaseID] {
        case .preparing(let preparing)
        where preparing.inference.identity == identity
            && preparing.pendingStop != nil:
            cancelExpiryTask(leaseID: leaseID)
            entries[leaseID] = .aborting(
                Aborting(
                    binding: Binding(inference: preparing.inference),
                    waiters: preparing.controlWaiters,
                    terminalState: .failed,
                    result: .failed))
            await preparing.executor.forceReleasePreparedInference(identity: identity)
            await preparing.inference.resourceRelease.fire()
            let controlWaiters = takeAbortingWaiters(identity: identity)
            entries[leaseID] = .terminal(
                Tombstone(
                    binding: Binding(inference: preparing.inference),
                    state: .failed,
                    createdAt: now()))
            resumePrepareWaiters(preparing.prepareWaiters, throwing: timeoutError)
            resumeControlWaiters(controlWaiters, with: .failed)
        case .starting(let starting)
        where starting.reserved.lease.identity == identity
            && starting.pendingStop != nil:
            entries[leaseID] = .aborting(
                Aborting(
                    binding: Binding(lease: starting.reserved.lease),
                    waiters: starting.controlWaiters,
                    terminalState: .failed,
                    result: .failed))
            await starting.reserved.executor.forceReleasePreparedInference(identity: identity)
            await starting.reserved.inference.resourceRelease.fire()
            let controlWaiters = takeAbortingWaiters(identity: identity)
            entries[leaseID] = .terminal(
                Tombstone(
                    binding: Binding(lease: starting.reserved.lease),
                    state: .failed,
                    createdAt: now()))
            resumeStartWaiters(starting.startWaiters, throwing: timeoutError)
            resumeControlWaiters(controlWaiters, with: .failed)
        default:
            break
        }
    }

    // MARK: - Expiry

    public func expireLeases(at instant: Date) async {
        let candidates = entries.compactMap { leaseID, entry -> (LeaseID, Entry)? in
            switch entry {
            case .preparing(let preparing) where preparing.expiresAt <= instant:
                return (leaseID, entry)
            case .reserved(let reserved) where reserved.lease.expiresAt <= instant:
                return (leaseID, entry)
            default:
                return nil
            }
        }

        for (leaseID, candidate) in candidates {
            switch candidate {
            case .preparing:
                guard case .preparing(var current)? = entries[leaseID] else { continue }
                if current.pendingStop == nil {
                    current.pendingStop = .expire
                    entries[leaseID] = .preparing(current)
                }
            case .reserved(let reserved):
                guard case .reserved(let current)? = entries[leaseID],
                    current.lease.identity == reserved.lease.identity,
                    current.lease.expiresAt <= instant
                else { continue }
                await expireReserved(current)
            default:
                break
            }
        }
        pruneTombstones(at: instant)
    }

    private func expireReserved(_ reserved: Reserved) async {
        let identity = reserved.lease.identity
        let leaseID = identity.leaseID
        cancelExpiryTask(leaseID: leaseID)
        entries[leaseID] = .aborting(
            Aborting(
                binding: Binding(lease: reserved.lease),
                terminalState: .expired,
                result: .expired))
        let stopped = await stopExecutor(
            identity: identity, executor: reserved.executor, cancel: false)
        await reserved.inference.resourceRelease.fire()
        let duplicateWaiters = takeAbortingWaiters(identity: identity)
        entries[leaseID] = .terminal(
            Tombstone(
                binding: Binding(lease: reserved.lease),
                state: stopped ? .expired : .failed,
                createdAt: now()))
        resumeControlWaiters(duplicateWaiters, with: stopped ? .expired : .failed)
    }

    private func scheduleExpiry(identity: AttemptIdentity, expiresAt: Date) {
        guard automaticallyExpire else { return }
        let delay = max(0, expiresAt.timeIntervalSince(now()))
        let nanosecondsDouble = min(delay * 1_000_000_000, Double(UInt64.max))
        let nanoseconds = UInt64(nanosecondsDouble.rounded(.up))
        expiryTasks[identity.leaseID] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard let self else { return }
            await self.expireLeases(at: expiresAt)
        }
    }

    private func cancelExpiryTask(leaseID: LeaseID) {
        expiryTasks.removeValue(forKey: leaseID)?.cancel()
    }

    // MARK: - Completion / inspection

    private func observeCompletion(_ started: Started) {
        Task { [weak self] in
            await started.execution.completion.wait()
            await self?.markCompleted(started.lease)
        }
    }

    private func markCompleted(_ lease: PreparedLease) {
        let leaseID = lease.identity.leaseID
        guard case .started(let current)? = entries[leaseID],
            current.lease.identity == lease.identity
        else { return }
        entries[leaseID] = .terminal(
            Tombstone(
                binding: Binding(lease: lease),
                state: .completed,
                createdAt: now()))
    }

    public func state(of identity: AttemptIdentity) -> PreparedLeaseState? {
        guard let entry = entries[identity.leaseID],
            entry.binding.identity == identity
        else { return nil }
        return entry.state
    }

    public func liveLeaseCount() -> Int {
        entries.values.reduce(into: 0) { count, entry in
            if [.preparing, .reserved, .starting, .started, .aborting, .cancelling]
                .contains(entry.state)
            {
                count += 1
            }
        }
    }

    func _testHasPendingStop(identity: AttemptIdentity) -> Bool {
        guard let entry = entries[identity.leaseID],
            entry.binding.identity == identity
        else { return false }
        switch entry {
        case .preparing(let preparing): return preparing.pendingStop != nil
        case .starting(let starting): return starting.pendingStop != nil
        default: return false
        }
    }

    // MARK: - State helpers

    private func takePreparing(identity: AttemptIdentity) -> Preparing? {
        guard case .preparing(let pending)? = entries[identity.leaseID],
            pending.inference.identity == identity
        else { return nil }
        return pending
    }

    private func takeStarting(identity: AttemptIdentity) -> Starting? {
        guard case .starting(let starting)? = entries[identity.leaseID],
            starting.reserved.lease.identity == identity
        else { return nil }
        return starting
    }

    private func takeAbortingWaiters(identity: AttemptIdentity) -> [ControlWaiter] {
        guard case .aborting(let aborting)? = entries[identity.leaseID],
            aborting.binding.identity == identity
        else { return [] }
        return aborting.waiters
    }

    private func takeCancellingWaiters(identity: AttemptIdentity) -> [ControlWaiter] {
        guard case .cancelling(let cancelling)? = entries[identity.leaseID],
            cancelling.started.lease.identity == identity
        else { return [] }
        return cancelling.waiters
    }

    private func resumePrepareWaiters(
        _ waiters: [PrepareWaiter],
        returning lease: PreparedLease
    ) {
        for waiter in waiters {
            waiter.resume(returning: lease)
        }
    }

    private func resumePrepareWaiters(_ waiters: [PrepareWaiter], throwing error: Error) {
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }

    private func resumeStartWaiters(
        _ waiters: [StartWaiter],
        returning result: PreparedLeaseStartResult
    ) {
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    private func resumeStartWaiters(_ waiters: [StartWaiter], throwing error: Error) {
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }

    private func resumeControlWaiters(
        _ waiters: [ControlWaiter],
        with result: PreparedLeaseControlResult
    ) {
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    private func error(for state: PreparedLeaseState) -> PreparedLeaseError {
        switch state {
        case .aborted, .aborting: return .aborted
        case .cancelled, .cancelling: return .cancelled
        case .expired: return .expired
        case .completed: return .completed
        case .preparing: return .notReady
        case .failed: return .failed("prepared inference failed")
        default: return .failed("invalid lease transition from \(state.rawValue)")
        }
    }

    private func pruneTombstones(at instant: Date) {
        let expired = entries.compactMap { leaseID, entry -> LeaseID? in
            guard case .terminal(let tombstone) = entry,
                instant.timeIntervalSince(tombstone.createdAt) >= tombstoneRetention
            else { return nil }
            return leaseID
        }
        for leaseID in expired {
            entries.removeValue(forKey: leaseID)
        }

        let tombstones = entries.compactMap {
            (leaseID, entry) -> (LeaseID, Date)? in
            guard case .terminal(let tombstone) = entry else { return nil }
            return (leaseID, tombstone.createdAt)
        }
        guard tombstones.count > maxTombstones else { return }
        let overflow = tombstones.count - maxTombstones
        for (leaseID, _) in tombstones.sorted(by: { $0.1 < $1.1 }).prefix(overflow) {
            entries.removeValue(forKey: leaseID)
        }
    }
}
