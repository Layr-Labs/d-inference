import Foundation

/// Operator debug control (`darkbloom addon status|hold|release`) through the
/// same-UID lifecycle mailbox, bound to the running provider's process identity.
public struct AddonHoldControlRequest: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable { case status, hold, release }

    /// The `busy_addon` of a hold placed from the command line.
    public static let operatorAddon = "operator"
    /// Lease bounds of every hold. The CLI validates against them before
    /// sending: the provider drops a request outside them unanswered.
    public static let leaseSecondsRange: ClosedRange<Int> = AddonHold.leaseSecondsRange

    public let id: String
    public let target: ProcessIdentity
    public let action: Action
    /// `hold` only, within `leaseSecondsRange`.
    public let leaseSeconds: Int?
    /// `release` only: release even while the machine lock is held.
    public let force: Bool
    public let createdAt: Double

    public init(target: ProcessIdentity, action: Action, leaseSeconds: Int? = nil, force: Bool = false) {
        id = UUID().uuidString
        self.target = target
        self.action = action
        self.leaseSeconds = leaseSeconds
        self.force = force
        createdAt = Date().timeIntervalSince1970
    }

    /// Only a request for this process created within the last minute (5 s
    /// of clock skew allowed): an operator command must not take effect long
    /// after the CLI stopped waiting for it.
    public func isValid(for identity: ProcessIdentity, now: Double = Date().timeIntervalSince1970) -> Bool {
        guard target == identity, UUID(uuidString: id) != nil, createdAt.isFinite,
              createdAt <= now + 5, now - createdAt <= 60 else { return false }
        switch action {
        case .hold: return leaseSeconds.map(Self.leaseSecondsRange.contains) ?? false
        case .status, .release: return leaseSeconds == nil
        }
    }
}

public struct AddonHoldControlStatus: Codable, Sendable, Equatable {
    public enum Failure: String, Codable, Sendable {
        /// The provider is stopping or a model switch owns admission.
        case unavailable
        /// `release` without `--force` while an add-on still holds the
        /// machine lock (VMs may be running).
        case machineLockHeld = "machine_lock_held"
    }

    public let requestID: String
    public let failure: Failure?
    /// Active holds after the command.
    public let holds: [AddonHoldView]
    public let machineLockHeld: Bool

    public init(requestID: String, failure: Failure? = nil, holds: [AddonHoldView], machineLockHeld: Bool) {
        self.requestID = requestID
        self.failure = failure
        self.holds = holds
        self.machineLockHeld = machineLockHeld
    }

    // Works with both the mailbox's default coder and snake-case coders.
    enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case failure, holds, machineLockHeld
    }
}

/// Active holds as the daemon state file reports them. Present whenever the
/// running provider serves the add-on socket, so its absence means an older
/// or standalone provider.
public struct AddonHoldSnapshot: Codable, Sendable, Equatable {
    public var holds: [AddonHoldView]
    public init(holds: [AddonHoldView]) { self.holds = holds }
}
