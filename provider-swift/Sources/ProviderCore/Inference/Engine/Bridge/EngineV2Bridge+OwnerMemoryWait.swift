// The owner's request waits for the memory that requests already running hold, instead of the memory 503 at once.

import Foundation

/// The owner's request on this Mac's local API (a pair's, on its leader), when it can't start now because requests
/// already running hold the memory it needs: it waits for them, instead of the memory 503 at once. The local API binds
/// this around each request it serves (`MultiModelBatchSchedulerEngine`), and `EngineV2Bridge.submitTokenized` reads
/// it. Nil for every other request: a Darkbloom request is refused at once, as before, so the coordinator sends it
/// elsewhere within its first-content budget.
///
/// - The request waits in arrival order behind the owner's requests already waiting on the slot (`OwnerMemoryQueue`).
///   The first one is tried again when a request on the slot ends, and at least every `retryInterval` (memory freed by
///   another slot or by a pair's rank says nothing to this one). A pair's first-token allowance and request deadline
///   start when the wait ends, as after the pair's lane queue.
/// - Past `limit` (`DARKBLOOM_LOCAL_MEMORY_WAIT_SECONDS`, 120 by default; 0 turns the wait off), or with
///   `maximumWaiting` requests already waiting, it is refused as busy (`busyRefusal`).
/// - A request larger than the slot holds with nothing else running is refused at once (`exceedsIdleRefusal`).
/// - A request the local router would pass on to another of the owner's Macs, or to the network, waits nowhere
///   (`waitsHere`): it is refused at once, and the router passes it on.
struct OwnerMemoryWait: Sendable {
    @TaskLocal static var current: OwnerMemoryWait?

    static let environmentName = "DARKBLOOM_LOCAL_MEMORY_WAIT_SECONDS"
    static let defaultLimit: Duration = .seconds(120)
    static let maximumLimit: Duration = .seconds(600)
    /// The owner's requests that may wait on one slot at once, as many as may wait for a pair's lane.
    static let maximumWaiting = DistributedRequestQueue.defaultMaximumWaiting

    /// The refusals the local API answers in words (`LocalMemoryRefusal`). Both keep the capacity prefix, so every
    /// other reader still sees a retryable capacity refusal.
    static let busyRefusal = "token_budget_exhausted: memory busy: requests already running hold the memory this "
        + "request needs"
    static let exceedsIdleRefusal = "token_budget_exhausted: request exceeds the memory this slot holds with "
        + "nothing else running"

    /// How long a request may wait; zero refuses it at once, in the busy words.
    let limit: Duration
    /// The longest the first waiter goes without trying again while no request on its slot ends.
    let retryInterval: Duration
    /// Whether a request for `model` waits here; false where the local router would pass it on.
    let waitsHere: @Sendable (_ model: String) async -> Bool

    init(limit: Duration = OwnerMemoryWait.defaultLimit, retryInterval: Duration = .seconds(1),
         waitsHere: @escaping @Sendable (_ model: String) async -> Bool = { _ in true }) {
        self.limit = max(.zero, min(limit, Self.maximumLimit))
        self.retryInterval = max(.milliseconds(1), retryInterval)
        self.waitsHere = waitsHere
    }

    /// The owner's setting: whole seconds in 0...600, 0 turning the wait off. Anything else, or nothing, is the default.
    static func limit(environment: [String: String] = ProcessInfo.processInfo.environment) -> Duration {
        guard let raw = environment[environmentName]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let seconds = Int(raw), seconds >= 0, .seconds(seconds) <= maximumLimit else { return defaultLimit }
        return .seconds(seconds)
    }
}

/// How a memory refusal of the owner's request reads.
enum OwnerMemoryRefusal: Equatable, Sendable {
    /// The slot would hold the request with nothing else running: requests already running hold the memory.
    case busy
    /// The request is larger than the slot holds with nothing else running.
    case exceedsIdle

    /// What a capacity refusal's own words say. The bridge adds what only its state says
    /// (`EngineV2Bridge.ownerMemoryRefusal`); the local API reads the words alone (`LocalMemoryRefusal`).
    init(refusal message: String) {
        if message == OwnerMemoryWait.exceedsIdleRefusal
            || message.contains(EngineV2Bridge.glm5NextExceedsSlotCapacity) {
            self = .exceedsIdle
        } else if !DistributedMemoryAbort.matches(message),
                  let figures = EngineV2Translation.capacityRefusalFigures(message) {
            // A single Mac's engine says what it holds at all; a pair, the context its memory holds idle. A pair's
            // abort of a request that ran is in the same words, and busy: the request fit when it started.
            self = !figures.pair || figures.needed > figures.available ? .exceedsIdle : .busy
        } else {
            self = .busy
        }
    }
}

/// The owner's requests waiting for memory on one slot, oldest first (`EngineV2Bridge.ownerMemoryWaiters`). Owned by
/// the bridge actor; every method is synchronous. Only the first may try again: a waiter is woken when it becomes
/// first, and the first when a request on the slot ends. One woken while it isn't parked resumes at its next park.
struct OwnerMemoryQueue {
    private(set) var waiting: [UUID] = []
    private var parked: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var woken: Set<UUID> = []

    var isEmpty: Bool { waiting.isEmpty }
    func isFirst(_ ticket: UUID) -> Bool { waiting.first == ticket }

    /// A place at the back, or nil when `OwnerMemoryWait.maximumWaiting` already wait.
    mutating func enqueue() -> UUID? {
        guard waiting.count < OwnerMemoryWait.maximumWaiting else { return nil }
        let ticket = UUID()
        waiting.append(ticket)
        return ticket
    }

    /// Parks a waiter until it is woken; one woken since its last park, or no longer waiting, resumes at once.
    mutating func park(_ ticket: UUID, _ continuation: CheckedContinuation<Void, Never>) {
        if woken.remove(ticket) != nil || !waiting.contains(ticket) {
            continuation.resume()
        } else {
            parked[ticket] = continuation
        }
    }

    mutating func wake(_ ticket: UUID) {
        if let continuation = parked.removeValue(forKey: ticket) {
            continuation.resume()
        } else if waiting.contains(ticket) {
            woken.insert(ticket)
        }
    }

    /// Memory may have been freed: the first waiter tries again.
    mutating func wakeFirst() {
        if let first = waiting.first { wake(first) }
    }

    /// The waiter left, started or refused; when it was first, the next becomes first and tries.
    mutating func leave(_ ticket: UUID) {
        let wasFirst = isFirst(ticket)
        waiting.removeAll { $0 == ticket }
        woken.remove(ticket)
        parked.removeValue(forKey: ticket)?.resume()
        if wasFirst { wakeFirst() }
    }
}

extension EngineV2Bridge {
    /// The owner's request (`OwnerMemoryWait`): `attempt` submits it once, its pair budgets starting at the instant it
    /// is given. A memory refusal of a request the slot holds idle waits for a request on the slot to end, then tries
    /// again, within `wait.limit`; one the slot can't hold idle is refused at once (`exceedsIdleRefusal`), and one past
    /// the wait as busy (`busyRefusal`). Any other outcome is the attempt's own.
    func submittingOwnerRequest(
        _ wait: OwnerMemoryWait, model: String, worstCaseTokens: Int, origin: ContinuousClock.Instant?,
        attempt: (ContinuousClock.Instant?) async throws -> AsyncStream<GenerationEvent>
    ) async throws -> AsyncStream<GenerationEvent> {
        let deadline = ContinuousClock.now.advanced(by: wait.limit)
        var origin = origin
        var ticket: UUID?
        defer { if let ticket { ownerMemoryWaiters.leave(ticket) } }
        // Asked once, and only when the request would wait: the router reads the saved route and the account key.
        var waitsHere: Bool?
        // Nobody overtakes a waiter: a request that finds the owner's requests waiting starts behind them.
        if !ownerMemoryWaiters.isEmpty {
            let waits = wait.limit > .zero ? await wait.waitsHere(model) : false
            waitsHere = waits
            if waits {
                ticket = try queueOwnerRequest()
                try await waitForOwnerMemory(ticket!, until: deadline, retry: wait.retryInterval, retrying: false)
                origin = .now
            }
        }
        while true {
            do {
                return try await attempt(origin)
            } catch {
                guard let refusal = await ownerMemoryRefusal(error, worstCaseTokens: worstCaseTokens) else { throw error }
                guard refusal == .busy else {
                    throw MultiModelBatchSchedulerEngineError.tokenBudgetExhausted(OwnerMemoryWait.exceedsIdleRefusal)
                }
                if waitsHere == nil { waitsHere = wait.limit > .zero ? await wait.waitsHere(model) : false }
                guard waitsHere == true else {
                    throw MultiModelBatchSchedulerEngineError.tokenBudgetExhausted(OwnerMemoryWait.busyRefusal)
                }
                if ticket == nil { ticket = try queueOwnerRequest() }
                // A `cluster local` response bound the refused attempt's first-token deadline; the next binds its own.
                DistributedHTTPResponseScope.current?.unbindRefusedAdmission()
                try await waitForOwnerMemory(ticket!, until: deadline, retry: wait.retryInterval, retrying: true)
                origin = .now
            }
        }
    }

    /// How a refusal of the owner's request reads (`OwnerMemoryRefusal`), with what only this slot's state says: a
    /// Mac whose memory allows it no request at all, and a contiguous slot's shared budget that wouldn't hold the
    /// request even once every request reservation is released. Nil for anything but a capacity refusal before the
    /// engine took the request: one the engine queued and then ended (a held head's) already waited there.
    func ownerMemoryRefusal(_ error: Error, worstCaseTokens: Int) async -> OwnerMemoryRefusal? {
        guard case .tokenBudgetExhausted(let message)? = error as? MultiModelBatchSchedulerEngineError,
              message != Self.headHoldLeaseExpired, message != Self.headHoldKVExhausted else {
            return nil
        }
        if message == Self.serviceAllowanceExhausted, effectiveServingConcurrency == 0 { return .exceedsIdle }
        if message.hasSuffix(Self.sharedKVNoHeadroom), let kvBudget,
           let bytes = requestReservationBytes(tokenCount: worstCaseTokens), bytes > 0,
           await !kvBudget.holdsOnceRequestsRelease(bytes: UInt64(bytes)) {
            return .exceedsIdle
        }
        return OwnerMemoryRefusal(refusal: message)
    }

    /// The owner's request's place in the slot's queue, or the busy refusal when the queue is full.
    private func queueOwnerRequest() throws -> UUID {
        guard let ticket = ownerMemoryWaiters.enqueue() else {
            throw MultiModelBatchSchedulerEngineError.tokenBudgetExhausted(OwnerMemoryWait.busyRefusal)
        }
        return ticket
    }

    /// Returns when `ticket` is first and should try: at once when `retrying` is false, otherwise when a request on
    /// the slot ends or `retry` passes. Busy at `deadline`; a cancelled request leaves.
    private func waitForOwnerMemory(_ ticket: UUID, until deadline: ContinuousClock.Instant, retry: Duration,
                                    retrying: Bool) async throws {
        var retrying = retrying
        while true {
            try Task.checkCancellation()
            let now = ContinuousClock.now
            guard now < deadline else {
                throw MultiModelBatchSchedulerEngineError.tokenBudgetExhausted(OwnerMemoryWait.busyRefusal)
            }
            if ownerMemoryWaiters.isFirst(ticket), !retrying { return }
            let first = ownerMemoryWaiters.isFirst(ticket)
            // The first waits for a request's end or its retry interval; any other, to become first.
            await parkOwnerRequest(ticket, for: first ? min(retry, deadline - now) : deadline - now)
            retrying = false
        }
    }

    private func parkOwnerRequest(_ ticket: UUID, for duration: Duration) async {
        let timer = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            await self?.wakeOwnerRequest(ticket)
        }
        defer { timer.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                ownerMemoryWaiters.park(ticket, continuation)
            }
        } onCancel: {
            Task { await self.wakeOwnerRequest(ticket) }
        }
    }

    private func wakeOwnerRequest(_ ticket: UUID) {
        ownerMemoryWaiters.wake(ticket)
    }

    /// A request on this slot ended and gave its memory back: the owner's first waiting request tries again. Never on
    /// a refusal, whose resources were never the waiters' to wait for.
    func noteOwnerMemoryReleased() {
        ownerMemoryWaiters.wakeFirst()
    }
}
