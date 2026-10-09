import Foundation

/// How a `darkbloom cluster link --fix` or `--remove` ended. Codes are an
/// output contract; add cases rather than renaming them.
public enum ClusterLinkRepairOutcome: Sendable, Equatable {
    /// A condition a fix must meet once the address is added.
    public enum Unmet: String, Encodable, Sendable, CaseIterable {
        case deviceNotReady
        case bridgeMembersChanged
        case defaultRouteChanged
        /// The bridge and route state could not be read afterwards.
        case stateUnreadable
    }

    // Nothing needed doing.
    case alreadyReady
    case alreadyAbsent
    case nothingRecorded
    // The change was approved and verified.
    case fixed
    case removed
    // Stopped before any prompt; nothing was changed.
    /// The link is in a state that adding an address does not cure.
    case nothingFixable(ClusterLinkReadinessState)
    case ambiguousPorts
    case deviceNotListed
    case machineIdentityUnavailable
    case recordUnavailable
    // The prompt did not lead to the change.
    case approvalDeclined
    case approvalUnavailable
    // Approved, but the result is not what was wanted.
    case commandFailed
    case appliedButNotReady([Unmet])
    case removalNotVerified

    public var code: String {
        switch self {
        case .alreadyReady: return "alreadyReady"
        case .alreadyAbsent: return "alreadyAbsent"
        case .nothingRecorded: return "nothingRecorded"
        case .fixed: return "fixed"
        case .removed: return "removed"
        case .nothingFixable: return "nothingFixable"
        case .ambiguousPorts: return "ambiguousPorts"
        case .deviceNotListed: return "deviceNotListed"
        case .machineIdentityUnavailable: return "machineIdentityUnavailable"
        case .recordUnavailable: return "recordUnavailable"
        case .approvalDeclined: return "approvalDeclined"
        case .approvalUnavailable: return "approvalUnavailable"
        case .commandFailed: return "commandFailed"
        case .appliedButNotReady: return "appliedButNotReady"
        case .removalNotVerified: return "removalNotVerified"
        }
    }

    /// 0 when the wanted end state holds; otherwise one status per kind of
    /// stop, so a caller can tell "declined" from "could not ask".
    public var exitCode: Int32 {
        switch self {
        case .alreadyReady, .alreadyAbsent, .nothingRecorded, .fixed, .removed: return 0
        case .nothingFixable, .ambiguousPorts, .deviceNotListed, .machineIdentityUnavailable, .recordUnavailable: return 1
        case .approvalDeclined: return 2
        case .approvalUnavailable: return 3
        case .commandFailed, .appliedButNotReady, .removalNotVerified: return 4
        }
    }
}

/// What a fix or removal did, by device and interface name only. The address
/// involved is never part of the encoded result or its text.
public struct ClusterLinkRepairResult: Encodable, Sendable, Equatable {
    public enum Operation: String, Encodable, Sendable { case fix, remove }

    public let schema = "darkbloom_cluster_link_repair_v1"
    public let operation: Operation
    public let outcome: ClusterLinkRepairOutcome
    public let device: String?
    public let interface: String?
    /// The devices to choose among when the outcome is `ambiguousPorts`.
    public let candidates: [String]
    /// Set only for `approvalUnavailable`: the command an administrator can
    /// run instead. It contains the address, so it is never encoded; the
    /// command line prints it on standard error.
    public let manualCommand: String?

    init(operation: Operation, outcome: ClusterLinkRepairOutcome, device: String? = nil, interface: String? = nil,
         candidates: [String] = [], manualCommand: String? = nil) {
        self.operation = operation
        self.outcome = outcome
        self.device = device
        self.interface = interface
        self.candidates = candidates
        self.manualCommand = manualCommand
    }

    private enum CodingKeys: String, CodingKey {
        case schema, operation, outcome, state, unmet, device, interface, candidates, message
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(operation, forKey: .operation)
        try container.encode(outcome.code, forKey: .outcome)
        if case .nothingFixable(let state) = outcome { try container.encode(state, forKey: .state) }
        if case .appliedButNotReady(let unmet) = outcome { try container.encode(unmet, forKey: .unmet) }
        try container.encodeIfPresent(device, forKey: .device)
        try container.encodeIfPresent(interface, forKey: .interface)
        if !candidates.isEmpty { try container.encode(candidates, forKey: .candidates) }
        try container.encode(message, forKey: .message)
    }
}
