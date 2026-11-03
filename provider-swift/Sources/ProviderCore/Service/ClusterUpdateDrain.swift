import Foundation

/// The cluster service supervisor's request to this Mac's coordinator-paired part during the pair's coordinated
/// update (`ClusterPairUpdateCycle`), through the part's lifecycle mailbox. Unlike a stop, the drain is undone when
/// the update is given up: the part takes requests again on the same coordinator connection.
public struct ClusterUpdateDrainRequest: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable {
        /// Take no new requests and finish the accepted ones within `timeoutSeconds`; take requests again when they
        /// do not finish. Nothing accepted is cancelled.
        case drain
        /// The update was given up after the part drained: take requests again.
        case release
    }

    public let id: String
    public let action: Action
    public let target: ProcessIdentity
    public let timeoutSeconds: Int
    public let createdAt: Double

    public init(action: Action, target: ProcessIdentity, timeoutSeconds: Int, createdAt: Double = Date().timeIntervalSince1970) {
        id = UUID().uuidString
        self.action = action
        self.target = target
        self.timeoutSeconds = timeoutSeconds
        self.createdAt = createdAt
    }

    public func isValid(for identity: ProcessIdentity, now: Double = Date().timeIntervalSince1970) -> Bool {
        target == identity && UUID(uuidString: id) != nil && (0...3600).contains(timeoutSeconds)
            && createdAt.isFinite && createdAt <= now + 5 && now - createdAt <= 3605
    }
}

public struct ClusterUpdateDrainStatus: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        /// New requests are refused; the accepted ones are finishing.
        case draining
        /// Nothing accepted is left. New requests stay refused until the part stops, is released, or its hold ends.
        case drained
        /// Accepted requests were still running at the bound: the part takes requests again; nothing was cancelled.
        case timedOut
        /// The part serves no requests of its own (it holds no pair slot): nothing to drain on this Mac.
        case notServing
        /// A stop, a model change or another drain owns admission: not drained.
        case refused
        /// The drain was undone on request: the part takes requests again.
        case released
    }

    public var requestID: String
    public var outcome: Outcome
    public var remaining: Int

    public init(requestID: String, outcome: Outcome, remaining: Int) {
        self.requestID = requestID
        self.outcome = outcome
        self.remaining = remaining
    }
}
