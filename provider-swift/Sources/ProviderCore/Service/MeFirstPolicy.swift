import Foundation

/// Me first: while the owner uses this Mac through its local API, Darkbloom
/// work pauses; it resumes once no local request has been in flight for
/// `idleMs`. A pure state machine over a millisecond clock the caller supplies
/// (`ProviderLoop+MeFirst` passes the wall clock), so every edge is a plain
/// input in tests. Each input is O(1): a counter and two timestamps.
///
/// ```
/// Open ──a local request starts──▶ Paused(since, lastUse)
/// Paused ──a local request starts or ends──▶ Paused(lastUse = now)
/// Paused ──none in flight and now − lastUse ≥ idle──▶ Open
/// ```
struct MeFirstPolicy: Sendable, Equatable {
    /// One edge of a local request's use of this Mac's engine: it acquired a
    /// model (`start`) or released it (`end`).
    enum LocalUse: Sendable, Equatable { case start, end }

    /// What an input changed.
    enum Transition: Sendable, Equatable { case paused, resumed }

    /// How long with no local request in flight before Darkbloom work resumes.
    let idleMs: Int64
    /// Local requests that started and have not ended.
    private(set) var inFlight = 0
    /// When the current pause began; nil while open to Darkbloom.
    private(set) var sinceMs: Int64?
    /// When the owner's last local request started or ended; nil before the first.
    private(set) var lastUseMs: Int64?

    init(idleMs: Int64) {
        self.idleMs = max(0, idleMs)
    }

    var isPausingPublic: Bool { sinceMs != nil }

    /// When Darkbloom work resumes if nothing else happens; nil while open or
    /// while a local request is in flight.
    var resumesAtMs: Int64? {
        guard isPausingPublic, inFlight == 0, let lastUseMs else { return nil }
        let (deadline, overflow) = lastUseMs.addingReportingOverflow(idleMs)
        return overflow ? .max : deadline
    }

    /// A local request started. The first one pauses Darkbloom work.
    mutating func localStarted(atMs now: Int64) -> Transition? {
        inFlight += 1
        lastUseMs = now
        guard sinceMs == nil else { return nil }
        sinceMs = now
        return .paused
    }

    /// A local request ended; the end of the last one starts the idle
    /// countdown. An end without a start changes nothing.
    mutating func localEnded(atMs now: Int64) {
        guard inFlight > 0 else { return }
        inFlight -= 1
        lastUseMs = now
    }

    /// Resumes Darkbloom work once no local request has been in flight for
    /// `idleMs`. A clock that went back restarts the countdown from now, so
    /// the pause outlasts the jump by one idle time at most.
    mutating func tick(atMs now: Int64) -> Transition? {
        guard isPausingPublic, inFlight == 0, let lastUseMs else { return nil }
        guard now >= lastUseMs else {
            self.lastUseMs = now
            return nil
        }
        guard now - lastUseMs >= idleMs else { return nil }
        sinceMs = nil
        return .resumed
    }

    /// `darkbloomRequestsFinishing`: the Darkbloom requests still running,
    /// which the caller counts only while paused.
    func snapshot(darkbloomRequestsFinishing: Int) -> MeFirstSnapshot {
        MeFirstSnapshot(idleMs: idleMs, paused: isPausingPublic, sinceMs: sinceMs, lastUseMs: lastUseMs,
                        resumesAtMs: resumesAtMs, localRequestsInFlight: inFlight,
                        darkbloomRequestsFinishing: darkbloomRequestsFinishing)
    }
}

/// Me first as `darkbloom status` reads it (`DaemonState.meFirst`). Times are
/// Unix milliseconds.
public struct MeFirstSnapshot: Codable, Sendable, Equatable {
    /// How long with no request of the owner's before Darkbloom work resumes.
    public var idleMs: Int64
    /// Darkbloom work is paused for the owner.
    public var paused: Bool
    /// When the current pause began; nil while open to Darkbloom.
    public var sinceMs: Int64?
    /// When the owner's last local request started or ended; nil before the first.
    public var lastUseMs: Int64?
    /// When Darkbloom work resumes if the owner stays idle; nil while open or
    /// while a request of the owner's runs.
    public var resumesAtMs: Int64?
    /// The owner's local requests now running.
    public var localRequestsInFlight: Int
    /// Darkbloom requests accepted before the pause and still finishing; 0
    /// while open.
    public var darkbloomRequestsFinishing: Int

    public init(idleMs: Int64, paused: Bool, sinceMs: Int64? = nil, lastUseMs: Int64? = nil,
                resumesAtMs: Int64? = nil, localRequestsInFlight: Int = 0, darkbloomRequestsFinishing: Int = 0) {
        self.idleMs = idleMs
        self.paused = paused
        self.sinceMs = sinceMs
        self.lastUseMs = lastUseMs
        self.resumesAtMs = resumesAtMs
        self.localRequestsInFlight = localRequestsInFlight
        self.darkbloomRequestsFinishing = darkbloomRequestsFinishing
    }
}
