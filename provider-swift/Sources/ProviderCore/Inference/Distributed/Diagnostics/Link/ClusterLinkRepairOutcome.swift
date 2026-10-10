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
        /// The job that keeps the address is not installed and loaded as written,
        /// whether or not the address itself is there.
        case addressKeeperNotRunning
    }

    // Nothing was changed.
    /// `--dry-run`: the commands an approval would run were worked out and not run.
    case dryRun
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
    // Link setup v2.
    /// Something the approval cannot cure is in the way; nothing was changed.
    case isolationRefused([ClusterLinkIsolationFinding])
    /// Approved, but these findings still hold for the port afterwards.
    case appliedButNotIsolated([ClusterLinkIsolationFinding])

    public var code: String {
        switch self {
        case .dryRun: return "dryRun"
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
        case .isolationRefused: return "isolationRefused"
        case .appliedButNotIsolated: return "appliedButNotIsolated"
        }
    }

    /// 0 when the wanted end state holds; otherwise one status per kind of
    /// stop, so a caller can tell "declined" from "could not ask".
    public var exitCode: Int32 {
        switch self {
        case .dryRun, .alreadyReady, .alreadyAbsent, .nothingRecorded, .fixed, .removed: return 0
        case .nothingFixable, .ambiguousPorts, .deviceNotListed, .machineIdentityUnavailable, .recordUnavailable,
             .isolationRefused: return 1
        case .approvalDeclined: return 2
        case .approvalUnavailable: return 3
        case .commandFailed, .appliedButNotReady, .removalNotVerified, .appliedButNotIsolated: return 4
        }
    }
}

/// What a fix or removal did, by device and interface name only. The address
/// involved is never part of the encoded result or its text, except in the
/// commands of a dry run, whose whole purpose is to show them.
public struct ClusterLinkRepairResult: Encodable, Sendable, Equatable {
    public enum Operation: String, Encodable, Sendable { case fix, remove }

    public let schema = "darkbloom_cluster_link_repair_v1"
    public let operation: Operation
    public let outcome: ClusterLinkRepairOutcome
    public let device: String?
    public let interface: String?
    /// The devices to choose among when the outcome is `ambiguousPorts`.
    public let candidates: [String]
    /// Whether the fix installs the job that keeps the address, as opposed to
    /// adding the address alone. Nil where no fix was attempted or planned.
    public let durable: Bool?
    /// Whether this is link setup v2: the port gets, or got, its own network
    /// service outside every bridge. Nil for the first version's fix and removal.
    public let isolated: Bool?
    /// Set only for `dryRun`: the exact commands an approval would run, in order.
    public let plannedCommands: [String]
    /// Set only for `approvalUnavailable`: the commands an administrator can
    /// run instead. They contain the address, so they are never encoded; the
    /// command line prints them on standard error.
    public let manualCommands: [String]
    /// For the sentences of link setup v2 only, never encoded: the port's
    /// hardware port name ("Thunderbolt 2") and the bridge it is or was in.
    let hardwarePort: String?
    let bridge: String?

    init(operation: Operation, outcome: ClusterLinkRepairOutcome, device: String? = nil, interface: String? = nil,
         candidates: [String] = [], durable: Bool? = nil, isolated: Bool? = nil, plannedCommands: [String] = [],
         manualCommands: [String] = [], hardwarePort: String? = nil, bridge: String? = nil) {
        self.operation = operation
        self.outcome = outcome
        self.device = device
        self.interface = interface
        self.candidates = candidates
        self.durable = durable
        self.isolated = isolated
        self.plannedCommands = plannedCommands
        self.manualCommands = manualCommands
        self.hardwarePort = hardwarePort
        self.bridge = bridge
    }

    private enum CodingKeys: String, CodingKey {
        case schema, operation, outcome, state, unmet, findings, device, interface, candidates, durable, isolated, plannedCommands, message
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(operation, forKey: .operation)
        try container.encode(outcome.code, forKey: .outcome)
        if case .nothingFixable(let state) = outcome { try container.encode(state, forKey: .state) }
        if case .appliedButNotReady(let unmet) = outcome { try container.encode(unmet, forKey: .unmet) }
        if case .isolationRefused(let findings) = outcome { try container.encode(findings, forKey: .findings) }
        if case .appliedButNotIsolated(let findings) = outcome { try container.encode(findings, forKey: .findings) }
        try container.encodeIfPresent(device, forKey: .device)
        try container.encodeIfPresent(interface, forKey: .interface)
        if !candidates.isEmpty { try container.encode(candidates, forKey: .candidates) }
        try container.encodeIfPresent(durable, forKey: .durable)
        try container.encodeIfPresent(isolated, forKey: .isolated)
        if !plannedCommands.isEmpty { try container.encode(plannedCommands, forKey: .plannedCommands) }
        try container.encode(message, forKey: .message)
    }
}
