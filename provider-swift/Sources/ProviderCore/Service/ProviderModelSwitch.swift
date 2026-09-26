import Foundation

/// Owner-only request bound to the running process, never just a reusable PID.
public struct ProviderModelSwitchRequest: Codable, Sendable, Equatable {
    public let id: String
    public let target: ProcessIdentity
    public let models: [String]
    public let timeoutSeconds: Int
    public let createdAt: Double

    public init(id: String = UUID().uuidString, target: ProcessIdentity, models: [String], timeoutSeconds: Int,
                createdAt: Double = Date().timeIntervalSince1970) {
        self.id = id
        self.target = target
        self.models = models
        self.timeoutSeconds = timeoutSeconds
        self.createdAt = createdAt
    }

    public func isValid(for identity: ProcessIdentity, now: Double = Date().timeIntervalSince1970) -> Bool {
        target == identity && UUID(uuidString: id) != nil && (0...3600).contains(timeoutSeconds)
            && !models.isEmpty && models.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && Set(models).count == models.count
            && createdAt.isFinite && now.isFinite && createdAt <= now + 5 && now - createdAt <= 3605
    }
}

public struct ProviderModelSwitchStatus: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        case serving, validating, draining, switching, switched, timedOut, failed, busy
    }

    public var requestID: String?
    public var outcome: Outcome
    public var models: [String]
    public var remaining: Int
    public var message: String?

    // Compatible with both mailbox coding and DaemonState's snake-case coding.
    enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case outcome, models, remaining, message
    }

    public init(requestID: String? = nil, outcome: Outcome = .serving, models: [String] = [],
                remaining: Int = 0, message: String? = nil) {
        self.requestID = requestID
        self.outcome = outcome
        self.models = models
        self.remaining = remaining
        self.message = message
    }
}
