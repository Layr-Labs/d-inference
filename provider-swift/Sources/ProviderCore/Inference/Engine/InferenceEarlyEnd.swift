import Foundation

/// Why the coordinator cancelled a request, from its `cancel` message's `reason` and `paid` keys, which coordinators
/// before them do not send. `code` is the coordinator's bounded cancel cause (`client_gone_post`, `hedge_loser`,
/// `first_chunk_timeout`, …); `paid` says whether it settles, and pays for, the partial `inference_complete` this Mac
/// sends after the cancel.
public struct CoordinatorCancelReason: Sendable, Equatable {
    public var code: String
    public var paid: Bool

    public init(code: String, paid: Bool) {
        self.code = code
        self.paid = paid
    }
}

/// What stopped a request after it had sent output.
public enum InferenceEarlyEndCause: Sendable, Equatable {
    /// A coordinator `cancel`; nil when that coordinator sends no reason.
    case coordinatorCancel(CoordinatorCancelReason?)
    /// This Mac's connection to the coordinator dropped.
    case connectionLost
    /// This Mac stopped it: a forced drain, a shutdown or an add-on hold. The partial answer goes out on a live
    /// connection, and the coordinator settles it as a completion.
    case stoppedOnThisMac

    /// The coordinator pays the partial answer this Mac sends after the stop. False when that is not known: a
    /// cancel without a reason may or may not be paid.
    var isPaid: Bool {
        switch self {
        case .stoppedOnThisMac: true
        case .coordinatorCancel(let reason): reason?.paid == true
        case .connectionLost: false
        }
    }
}

/// Served requests that ended early, by what stopped them. Each one is in exactly one count.
public struct EndedEarlyCounts: Codable, Sendable, Equatable {
    /// The requester left mid-answer; the coordinator pays for the work done.
    public var requesterLeftPaid: UInt64 = 0
    /// The coordinator stopped it for another reason and pays for the work done.
    public var otherPaid: UInt64 = 0
    /// This Mac stopped it (a drain or an add-on hold); paid as a completion.
    public var stoppedOnThisMac: UInt64 = 0
    /// Another Mac answered first; unpaid.
    public var anotherMacFirst: UInt64 = 0
    /// This Mac's first words came after the request's deadline; unpaid.
    public var startedTooLate: UInt64 = 0
    /// The coordinator stopped it for another reason and does not pay.
    public var otherUnpaid: UInt64 = 0
    /// This Mac's connection to the coordinator dropped; unpaid.
    public var connectionLost: UInt64 = 0
    /// A coordinator cancel that gave no reason (an older coordinator).
    public var noReason: UInt64 = 0

    public init() {}

    public var total: UInt64 {
        requesterLeftPaid + otherPaid + stoppedOnThisMac + anotherMacFirst + startedTooLate + otherUnpaid
            + connectionLost + noReason
    }

    public mutating func add(_ cause: InferenceEarlyEndCause) {
        switch cause {
        case .connectionLost: connectionLost += 1
        case .stoppedOnThisMac: stoppedOnThisMac += 1
        case .coordinatorCancel(nil): noReason += 1
        case .coordinatorCancel(let given?):
            switch (given.paid, given.code) {
            case (true, "client_gone_post"): requesterLeftPaid += 1
            case (true, _): otherPaid += 1
            case (false, "hedge_loser"): anotherMacFirst += 1
            case (false, "first_chunk_timeout"), (false, "late_content"): startedTooLate += 1
            case (false, _): otherUnpaid += 1
            }
        }
    }

    // A count a newer or older daemon did not write reads as zero.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requesterLeftPaid = try c.decodeIfPresent(UInt64.self, forKey: .requesterLeftPaid) ?? 0
        otherPaid = try c.decodeIfPresent(UInt64.self, forKey: .otherPaid) ?? 0
        stoppedOnThisMac = try c.decodeIfPresent(UInt64.self, forKey: .stoppedOnThisMac) ?? 0
        anotherMacFirst = try c.decodeIfPresent(UInt64.self, forKey: .anotherMacFirst) ?? 0
        startedTooLate = try c.decodeIfPresent(UInt64.self, forKey: .startedTooLate) ?? 0
        otherUnpaid = try c.decodeIfPresent(UInt64.self, forKey: .otherUnpaid) ?? 0
        connectionLost = try c.decodeIfPresent(UInt64.self, forKey: .connectionLost) ?? 0
        noReason = try c.decodeIfPresent(UInt64.self, forKey: .noReason) ?? 0
    }
}
