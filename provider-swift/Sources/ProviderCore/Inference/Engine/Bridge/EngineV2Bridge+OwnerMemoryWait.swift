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
        self = .busy
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
