import Foundation

/// Me first: while the owner uses this Mac through its local API, Darkbloom work pauses; it resumes once the owner
/// has had no local request for `idleMs`. A pure state machine over a millisecond clock the caller supplies.
struct MeFirstPolicy: Sendable, Equatable {
    /// One edge of a local request's use of this Mac's engine.
    enum LocalUse: Sendable, Equatable { case start, end }

    /// What an input changed.
    enum Transition: Sendable, Equatable { case paused, resumed }

    let idleMs: Int64
    private(set) var inFlight = 0
    private(set) var sinceMs: Int64?
    private(set) var lastUseMs: Int64?

    init(idleMs: Int64) {
        self.idleMs = idleMs
    }

    var isPausingPublic: Bool { false }

    var resumesAtMs: Int64? { nil }

    mutating func localStarted(atMs now: Int64) -> Transition? { nil }

    mutating func localEnded(atMs now: Int64) {}

    mutating func tick(atMs now: Int64) -> Transition? { nil }
}

/// Me first as `darkbloom status` reads it (`DaemonState.meFirst`).
public struct MeFirstSnapshot: Codable, Sendable, Equatable {
    public var idleMs: Int64
    public var paused: Bool
    public var sinceMs: Int64?
    public var lastUseMs: Int64?
    public var resumesAtMs: Int64?
    public var localRequestsInFlight: Int
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
