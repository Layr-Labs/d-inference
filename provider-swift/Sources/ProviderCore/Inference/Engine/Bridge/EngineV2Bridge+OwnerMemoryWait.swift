// The owner's request waits for the memory that requests already running hold, instead of the memory 503 at once.

import Foundation
import MLXLMCommon

/// The owner's request on this Mac's local API (a pair's, on its leader), when it can't start now because requests
/// already running hold the memory it needs: it waits for them, instead of the memory 503 at once. The local API binds
/// this around each request it serves through `MultiModelBatchSchedulerEngine`, and `EngineV2Bridge.submitTokenized`
/// reads it. Nil for every other request: a Darkbloom request is refused at once, as before, so the coordinator sends
/// it elsewhere within its first-content budget; Nemotron Super's local engines keep their own admission.
///
/// - The request waits in arrival order behind the owner's requests already waiting on the slot (`OwnerMemoryQueue`).
///   The first one is tried again when a request on the slot ends, and at least every `retryInterval` (memory freed by
///   another slot or by a pair's rank says nothing to this one). A pair's request deadline, and its first-token
///   allowance where `waitsForFirstToken` is off, start when the wait ends, as after the pair's lane queue.
/// - One the engine queued and ended before admitting it (its admission lease, a full paged pool's requeues) waits the
///   same way and is submitted again (`EngineV2Bridge.ownerMemoryRefusal`), at the back of the engine's queue: the
///   owner's requests start in arrival order among those that waited here, not against one that went straight into
///   the engine's queue while nobody waited.
/// - It waits as long as it takes, unless the owner (`DARKBLOOM_LOCAL_MEMORY_WAIT_SECONDS`) or the request itself
///   (`X-Darkbloom-Max-Wait`) names a bound, in whole seconds, the shorter of the two (`effectiveLimit`; 0 refuses it
///   at once). Past that bound, still queued in the engine or not, or with `maximumWaiting` requests already waiting,
///   it is refused as busy (`busyRefusal`); a client that goes away ends its wait.
/// - A request larger than the slot holds with nothing else running is refused at once (`exceedsIdleRefusal`).
/// - A request the local router would pass on to another of the owner's Macs, or to the network, waits nowhere
///   (`waitsHere`): it is refused at once, and the router passes it on.
struct OwnerMemoryWait: Sendable {
    @TaskLocal static var current: OwnerMemoryWait?

    /// Whether the request this task serves is the owner's on the local API (`current` is bound; a request with a
    /// coordinator's first-content budget never is), a loop exit's continuation included. On a pair it is held to
    /// what the pair serves its owner (`DistributedResidentExecutionProfile.ownerServed`) and runs for the protocol's
    /// hour. The one rule the scheduler's `max_tokens` cut and the bridge's submission read.
    static func servesOwnerRequest(firstContentDeadline: FirstContentDeadline?) -> Bool {
        current != nil && firstContentDeadline == nil
    }
    /// The client's own bound on this request's wait (`requestLimitHeaderName`), bound by the local API around the
    /// request that names one.
    @TaskLocal static var requestLimit: Duration?

    static let environmentName = "DARKBLOOM_LOCAL_MEMORY_WAIT_SECONDS"
    static let firstTokenWaitEnvironmentName = "DARKBLOOM_LOCAL_FIRST_TOKEN_WAIT"
    /// `0`, `false`, `no` or `off` (`waitsForSharedGrant`): a GLM request that fits GLM alone but not its share beside
    /// other loaded models is refused at once as larger than memory, with 0.10.17's busy words, as 0.10.17 did.
    static let sharedGrantWaitEnvironmentName = "DARKBLOOM_GLM_SHARED_GRANT_WAIT"
    /// A request's own bound on its wait, in whole seconds; `0` refuses it at once when it can't start.
    static let requestLimitHeaderName = "X-Darkbloom-Max-Wait"
    /// The longest bound a setting or a request may name: far past any wait, and far from `Duration`'s range.
    static let maximumBoundSeconds = 1_000_000_000
    /// The owner's requests that may wait on one slot at once, as many as may wait for a pair's lane.
    static let maximumWaiting = DistributedRequestQueue.defaultMaximumWaiting

    /// The refusals the local API answers in words (`LocalMemoryRefusal`). Both keep the capacity prefix, so every
    /// other reader still sees a retryable capacity refusal.
    static let busyRefusal = "token_budget_exhausted: memory busy: requests already running hold the memory this "
        + "request needs"
    static let exceedsIdleRefusal = "token_budget_exhausted: request exceeds the memory this slot holds with "
        + "nothing else running"

    /// The owner's bound on a request's wait: nil, the default, waits as long as it takes; zero refuses it at once, in
    /// the busy words.
    let limit: Duration?
    /// The longest the first waiter goes without trying again while no request on its slot ends.
    let retryInterval: Duration
    let sharedGrantLimit: Duration
    /// Whether a request for `model` waits here; false where the local router would pass it on.
    let waitsHere: @Sendable (_ model: String) async -> Bool
    /// Whether the request, on a pair, waits for its first token as long as its request deadline allows, however long
    /// the prompts ahead of it take, instead of the pair's first-token allowance (`DistributedFirstTokenBudgetPolicy`:
    /// 10 s plus a share per prompt token, from its arrival). `DARKBLOOM_LOCAL_FIRST_TOKEN_WAIT=0` restores the
    /// allowance.
    let waitsForFirstToken: Bool

    init(limit: Duration? = nil, retryInterval: Duration = .seconds(1), sharedGrantLimit: Duration = .seconds(120),
         waitsForFirstToken: Bool = true,
         waitsHere: @escaping @Sendable (_ model: String) async -> Bool = { _ in true }) {
        self.limit = limit.map { max(.zero, $0) }
        self.retryInterval = max(.milliseconds(1), retryInterval)
        self.sharedGrantLimit = sharedGrantLimit
        self.waitsForFirstToken = waitsForFirstToken
        self.waitsHere = waitsHere
    }

    /// The bound this request waits within: the owner's and the request's own, the shorter; nil when neither names one.
    var effectiveLimit: Duration? { [limit, Self.requestLimit].compactMap { $0 }.min() }

    /// Whether a request for `model` may wait at all. With the wait off the router is never asked: it reads the saved
    /// route and the account key.
    func waits(model: String) async -> Bool {
        effectiveLimit == .zero ? false : await waitsHere(model)
    }

    /// The owner's setting: whole seconds, 0 turning the wait off. Anything else, or nothing, sets no bound.
    static func limit(environment: [String: String] = ProcessInfo.processInfo.environment) -> Duration? {
        bound(environment[environmentName])
    }

    /// A request's `requestLimitHeaderName`, read as the owner's setting is; nil for anything else or nothing.
    static func requestLimit(header value: String?) -> Duration? {
        bound(value)
    }

    private static func bound(_ value: String?) -> Duration? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), let seconds = Int(raw), seconds >= 0
        else { return nil }
        return .seconds(min(seconds, maximumBoundSeconds))
    }

    /// The owner's setting for `waitsForFirstToken`: exact `0`, `false`, `no` or `off` (trimmed, case-insensitive)
    /// restores the pair's first-token allowance; anything else, or nothing, waits.
    static func waitsForFirstToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        switchIsOn(environment[firstTokenWaitEnvironmentName])
    }

    /// The owner's setting for the GLM shared-grant wait (`sharedGrantWaitEnvironmentName`), read as
    /// `waitsForFirstToken` is: on unless it says off.
    static func waitsForSharedGrant(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        switchIsOn(environment[sharedGrantWaitEnvironmentName])
    }

    private static func switchIsOn(_ value: String?) -> Bool {
        guard let raw = value else { return true }
        return !["0", "false", "no", "off"].contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

/// What one attempt of the owner's request asked for that its refusal's words don't say: the bytes a contiguous
/// slot's shared KV budget refused (a native block engine's own estimate, not the per-token price). Bound by
/// `EngineV2Bridge.submittingOwnerRequest` around each attempt; written where `submitTokenized` refuses.
final class OwnerMemoryAttempt: @unchecked Sendable {
    @TaskLocal static var current: OwnerMemoryAttempt?

    private let lock = NSLock()
    private var refusedBytes: Int?

    var sharedKVRefusedBytes: Int? {
        get { lock.withLock { refusedBytes } }
        set { lock.withLock { refusedBytes = newValue } }
    }
}

/// How a memory refusal of the owner's request reads.
enum OwnerMemoryRefusal: Equatable, Sendable {
    /// The slot would hold the request with nothing else running: requests already running hold the memory.
    case busy
    /// A co-resident model holds part of the grant. It may stay loaded indefinitely.
    case sharedGrant
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
    /// is given, and holds it in the engine's queue no later than the wait's end (nil: no end). A memory refusal of a
    /// request the slot holds idle, or the engine's end of one it queued and never admitted, waits for a request on the
    /// slot to end, then tries again, within `wait.effectiveLimit` if it names one; one the slot can't hold idle is
    /// refused at once (`exceedsIdleRefusal`), and one past the wait as busy (`busyRefusal`). Any other outcome is the
    /// attempt's own.
    ///
    /// With me first on, each refusal it waits after asks Darkbloom work still queued to give way
    /// (`MeFirstOwnerRequest.makeRoom`), as a request waiting in the engine's queue does (`watchOwnerWait`). With me
    /// first off, Darkbloom requests are not ordered behind the owner's waiters: one that fits takes the memory first.
    func submittingOwnerRequest(
        _ wait: OwnerMemoryWait, model: String, worstCaseTokens: Int, origin: ContinuousClock.Instant?,
        attempt: (_ origin: ContinuousClock.Instant?, _ waitEnd: ContinuousClock.Instant?) async throws
            -> AsyncStream<GenerationEvent>
    ) async throws -> AsyncStream<GenerationEvent> {
        let start = ContinuousClock.now
        var deadline = wait.effectiveLimit.map { start.advanced(by: $0) }
        let makeRoom = MeFirstOwnerRequest.makeRoom
        var origin = origin
        var ticket: UUID?
        defer { if let ticket { ownerMemoryWaiters.leave(ticket) } }
        // Asked once, and only when the request would wait.
        var waitsHere: Bool?
        // Nobody overtakes a waiter: a request that finds the owner's requests waiting starts behind them.
        if !ownerMemoryWaiters.isEmpty {
            let waits = await wait.waits(model: model)
            waitsHere = waits
            if waits {
                let queued = try queueOwnerRequest()
                ticket = queued
                if deadline == nil, glmSoloGrant != nil, let bytes = requestReservationBytes(tokenCount: worstCaseTokens) {
                    while !ownerMemoryWaiters.isFirst(queued) {
                        try Task.checkCancellation()
                        if bytes > admissionCapacityBytes(), await fitsGLMSoloGrant(bytes) == true {
                            deadline = start.advanced(by: wait.sharedGrantLimit)
                            break
                        }
                        // Resizing and a change of queue head both wake this ticket. A wake
                        // during the quote is remembered, so neither transition can be missed.
                        await parkOwnerRequest(queued, for: nil)
                    }
                }
                try await waitForOwnerMemory(queued, until: deadline, retry: wait.retryInterval, retrying: false)
                origin = .now
            }
        }
        while true {
            let note = OwnerMemoryAttempt()
            do {
                return try await OwnerMemoryAttempt.$current.withValue(note) { try await attempt(origin, deadline) }
            } catch {
                guard let refusal = await ownerMemoryRefusal(error, worstCaseTokens: worstCaseTokens, attempt: note)
                else { throw error }
                guard refusal != .exceedsIdle else {
                    throw MultiModelBatchSchedulerEngineError.tokenBudgetExhausted(OwnerMemoryWait.exceedsIdleRefusal)
                }
                if refusal == .sharedGrant, deadline == nil {
                    deadline = start.advanced(by: wait.sharedGrantLimit)
                }
                if waitsHere == nil { waitsHere = await wait.waits(model: model) }
                guard waitsHere == true else {
                    throw MultiModelBatchSchedulerEngineError.tokenBudgetExhausted(OwnerMemoryWait.busyRefusal)
                }
                let queued = try ticket ?? queueOwnerRequest()
                ticket = queued
                // A `cluster local` response bound the refused attempt's first-token deadline; the next binds its own.
                DistributedHTTPResponseScope.current?.unbindRefusedAdmission()
                if deadline.map({ ContinuousClock.now < $0 }) ?? true { await makeRoom?() }
                try await waitForOwnerMemory(queued, until: deadline, retry: wait.retryInterval, retrying: true)
                origin = .now
            }
        }
    }

    /// How a refusal of the owner's request reads (`OwnerMemoryRefusal`), with what only this slot's state says: a
    /// Mac whose memory allows it no request at all; a contiguous slot's shared budget that wouldn't hold the bytes it
    /// refused (`attempt`) even once every request reservation is released; and a native block engine (Diffusion
    /// Gemma), which refuses a request it can't take now, for its width or its memory, in the figures a paged engine
    /// uses only for one that can never fit. A held head's end before admission (`headHoldLeaseExpired`,
    /// `headHoldKVExhausted`) and the wait's own end in the engine's queue (`busyRefusal`) read as busy. Nil for
    /// anything but a capacity refusal before the engine admitted the request.
    func ownerMemoryRefusal(_ error: Error, worstCaseTokens: Int,
                            attempt: OwnerMemoryAttempt? = nil) async -> OwnerMemoryRefusal? {
        guard case .tokenBudgetExhausted(let message)? = error as? MultiModelBatchSchedulerEngineError else {
            return nil
        }
        let noRows = message == Self.serviceAllowanceExhausted && effectiveServingConcurrency == 0
        if noRows || message.contains(Self.glm5NextExceedsSlotCapacity) {
            if glmSoloGrant != nil, let bytes = requestReservationBytes(tokenCount: worstCaseTokens), bytes > 0 {
                if let fits = await fitsGLMSoloGrant(bytes) {
                    if fits { return .sharedGrant }
                } else if bytes <= admissionCapacityBytes(), effectiveServingConcurrency > 0 {
                    // The peer left and the real grant grew during the hop to the slot owner.
                    return .busy
                }
            }
            return .exceedsIdle
        }
        if message.hasSuffix(Self.sharedKVNoHeadroom) {
            guard let kvBudget,
                  let bytes = attempt?.sharedKVRefusedBytes ?? requestReservationBytes(tokenCount: worstCaseTokens),
                  bytes > 0 else { return .busy }
            return await kvBudget.holdsOnceRequestsRelease(bytes: UInt64(bytes)) ? .busy : .exceedsIdle
        }
        if let native = ownedEngine as? CBv2NativeBlockEngine,
           let figures = EngineV2Translation.capacityRefusalFigures(message), !figures.pair {
            return figures.needed > native.capacity().kvBytesCapacity ? .exceedsIdle : .busy
        }
        return OwnerMemoryRefusal(refusal: message)
    }

    /// With the shared-grant wait off (`OwnerMemoryWait.waitsForSharedGrant`) no quote is installed, and every
    /// refusal reads as it did before the quote existed.
    func installGLMSoloGrant(environment: [String: String] = ProcessInfo.processInfo.environment,
                             _ quote: @escaping @Sendable () async -> UInt64?) {
        guard OwnerMemoryWait.waitsForSharedGrant(environment: environment) else { return }
        glmSoloGrant = quote
    }

    private func fitsGLMSoloGrant(_ bytes: Int) async -> Bool? {
        guard let grant = await glmSoloGrant?() else { return nil }
        let raw = Int(clamping: grant)
        let usable = raw - Int(Double(raw) * EngineV2Factory.glm5NextAdmissionWatermarkFraction)
        return bytes <= usable - glm5NextStepSetupBytes
    }

    /// The owner's request's place in the slot's queue, or the busy refusal when the queue is full.
    private func queueOwnerRequest() throws -> UUID {
        guard let ticket = ownerMemoryWaiters.enqueue() else {
            throw MultiModelBatchSchedulerEngineError.tokenBudgetExhausted(OwnerMemoryWait.busyRefusal)
        }
        return ticket
    }

    /// Returns when `ticket` is first and should try: at once when `retrying` is false, otherwise when a request on
    /// the slot ends or `retry` passes. Busy at `deadline` (nil: never); a cancelled request leaves.
    private func waitForOwnerMemory(_ ticket: UUID, until deadline: ContinuousClock.Instant?, retry: Duration,
                                    retrying: Bool) async throws {
        var retrying = retrying
        while true {
            try Task.checkCancellation()
            let now = ContinuousClock.now
            let remaining = deadline.map { now.duration(to: $0) }
            if let remaining, remaining <= .zero {
                throw MultiModelBatchSchedulerEngineError.tokenBudgetExhausted(OwnerMemoryWait.busyRefusal)
            }
            let first = ownerMemoryWaiters.isFirst(ticket)
            if first, !retrying { return }
            // The first waits for a request's end or its retry interval; any other, to become first.
            await parkOwnerRequest(ticket, for: first ? min(retry, remaining ?? retry) : remaining)
            retrying = false
        }
    }

    /// Parks until woken, or `duration` passes (nil: until woken).
    private func parkOwnerRequest(_ ticket: UUID, for duration: Duration?) async {
        let timer = duration.map { duration in
            Task { [weak self] in
                do { try await Task.sleep(for: duration) } catch { return }
                await self?.wakeOwnerRequest(ticket)
            }
        }
        defer { timer?.cancel() }
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
