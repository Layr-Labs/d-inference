import Foundation

/// One admission state shared by updates, CLI lifecycle commands and signals.
/// The loop actor owns it. Update staging is separate and still admits work.
struct ProviderDrain: Sendable {
    enum Owner: Sendable { case update, lifecycle }
    enum Phase: String, Codable, Sendable { case serving, draining, drained }
    private(set) var phase: Phase = .serving
    private(set) var owner: Owner?

    var refusing: Bool { phase != .serving }

    mutating func begin(_ owner: Owner) {
        // A cancelled update must never reopen or replace an explicit stop.
        if self.owner == .lifecycle { return }
        self.owner = owner
        phase = .draining
    }
    mutating func drained() { phase = .drained }
    mutating func resumeUpdate() {
        guard owner == .update else { return }
        owner = nil
        phase = .serving
    }
}

public struct ProviderDrainStatus: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable { case serving, draining, drained, timedOut, forced, busy }
    public var requestID: String?
    public var outcome: Outcome
    public var remaining: Int
    public var deadline: Double?
    public var coordinatorAcknowledged: Bool

    // Works with both the mailbox's default coder and DaemonStateFile's
    // convertTo/FromSnakeCase strategy (request_id becomes requestId).
    enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case outcome, remaining, deadline, coordinatorAcknowledged
    }

    public init(requestID: String? = nil, outcome: Outcome = .serving,
                remaining: Int = 0, deadline: Double? = nil, coordinatorAcknowledged: Bool = false) {
        self.requestID = requestID; self.outcome = outcome; self.remaining = remaining
        self.deadline = deadline; self.coordinatorAcknowledged = coordinatorAcknowledged
    }
}

public struct ProviderDrainRequest: Codable, Sendable, Equatable {
    public let id: String
    public let target: ProcessIdentity
    public let timeoutSeconds: Int
    public let force: Bool
    public let createdAt: Double

    public init(target: ProcessIdentity, timeoutSeconds: Int, force: Bool = false) {
        id = UUID().uuidString; self.target = target; self.timeoutSeconds = timeoutSeconds
        self.force = force; createdAt = Date().timeIntervalSince1970
    }

    public func isValid(for identity: ProcessIdentity, now: Double = Date().timeIntervalSince1970) -> Bool {
        target == identity && UUID(uuidString: id) != nil && (0...3600).contains(timeoutSeconds)
            && createdAt.isFinite && createdAt <= now + 5 && now - createdAt <= 3605
    }
}
