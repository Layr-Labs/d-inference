import Foundation

/// One add-on's hold on the Mac. Times are Unix milliseconds, as in the IPC
/// contract; the persisted record uses the same snake_case keys.
struct AddonHold: Codable, Sendable, Equatable {
    /// `draining` until accepted work finished and every model unloaded.
    enum State: String, Codable, Sendable { case draining, held }

    static let leaseSeconds: ClosedRange<Int> = 30...600

    var holdID: String
    var addon: String
    var vmBytes: UInt64
    var state: State
    var sinceMs: Int64
    var leaseSeconds: Int
    var leaseExpiresAtMs: Int64

    enum CodingKeys: String, CodingKey {
        case holdID = "hold_id", addon, vmBytes = "vm_bytes", state
        case sinceMs = "since_ms", leaseSeconds = "lease_seconds"
        case leaseExpiresAtMs = "lease_expires_at_ms"
    }

    init(holdID: String = UUID().uuidString.lowercased(), addon: String, vmBytes: UInt64,
         state: State, sinceMs: Int64, leaseSeconds: Int) {
        self.holdID = holdID
        self.addon = addon
        self.vmBytes = vmBytes
        self.state = state
        self.sinceMs = sinceMs
        self.leaseSeconds = leaseSeconds
        self.leaseExpiresAtMs = sinceMs + Int64(leaseSeconds) * 1_000
    }

    /// A renewal restarts the lease from now; it never shortens a hold below
    /// the requested duration.
    mutating func renew(leaseSeconds: Int, nowMs: Int64) {
        self.leaseSeconds = leaseSeconds
        leaseExpiresAtMs = nowMs + Int64(leaseSeconds) * 1_000
    }

    func leaseExpired(nowMs: Int64) -> Bool { leaseExpiresAtMs <= nowMs }

    var view: AddonHoldView {
        AddonHoldView(holdId: holdID, addon: addon, state: state.rawValue, sinceMs: sinceMs,
                      leaseExpiresAtMs: leaseExpiresAtMs, vmBytes: vmBytes)
    }
}

/// A hold as `darkbloom status` and `darkbloom addon` report it.
public struct AddonHoldView: Codable, Sendable, Equatable {
    public var holdId: String
    public var addon: String
    /// `draining`, `held`, `released` or `expired`.
    public var state: String
    public var sinceMs: Int64
    public var leaseExpiresAtMs: Int64
    public var vmBytes: UInt64

    public init(holdId: String, addon: String, state: String, sinceMs: Int64,
                leaseExpiresAtMs: Int64, vmBytes: UInt64) {
        self.holdId = holdId
        self.addon = addon
        self.state = state
        self.sinceMs = sinceMs
        self.leaseExpiresAtMs = leaseExpiresAtMs
        self.vmBytes = vmBytes
    }
}

/// Active holds, at most one per add-on, plus the outcome of recently ended
/// holds so a late `status`, `renew` or `release` gets a definite answer.
struct AddonHoldBook: Sendable {
    enum Outcome: String, Sendable { case released, expired }

    struct Ended: Sendable, Equatable {
        var hold: AddonHold
        var outcome: Outcome
    }

    static let endedLimit = 32

    private(set) var active: [String: AddonHold] = [:]
    private(set) var ended: [Ended] = []
    /// Expired leases kept because the machine lock is still held, so the
    /// keep is reported once per hold rather than on every check.
    var keptByMachineLock: Set<String> = []

    init(restoring holds: [AddonHold] = []) {
        for hold in holds { active[hold.addon] = hold }
    }

    var isEmpty: Bool { active.isEmpty }

    /// The hold the busy fields describe: the longest-standing one.
    var oldest: AddonHold? {
        active.values.min { ($0.sinceMs, $0.holdID) < ($1.sinceMs, $1.holdID) }
    }

    /// Every active hold shares the provider's phase.
    var state: AddonHold.State { active.values.contains { $0.state == .draining } ? .draining : .held }

    var sorted: [AddonHold] { active.values.sorted { ($0.sinceMs, $0.addon) < ($1.sinceMs, $1.addon) } }

    func active(holdID: String) -> AddonHold? { active.values.first { $0.holdID == holdID } }

    func ended(holdID: String) -> Ended? { ended.last { $0.hold.holdID == holdID } }

    mutating func insert(_ hold: AddonHold) { active[hold.addon] = hold }

    mutating func update(_ hold: AddonHold) {
        guard active[hold.addon]?.holdID == hold.holdID else { return }
        active[hold.addon] = hold
    }

    mutating func markHeld() {
        for addon in active.keys { active[addon]?.state = .held }
    }

    @discardableResult
    mutating func end(holdID: String, as outcome: Outcome) -> AddonHold? {
        guard let hold = active(holdID: holdID) else { return nil }
        active.removeValue(forKey: hold.addon)
        keptByMachineLock.remove(holdID)
        ended.append(Ended(hold: hold, outcome: outcome))
        if ended.count > Self.endedLimit { ended.removeFirst(ended.count - Self.endedLimit) }
        return hold
    }
}
