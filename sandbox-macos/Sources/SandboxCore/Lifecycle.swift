import Foundation

public enum SandboxLifecycleState: String, Codable, CaseIterable, Hashable, Sendable {
    case queued
    case reserving
    case preparing
    case booting
    case ready
    case executing
    case stopping
    case checkpointing
    case stopped
    case stoppedLocal = "stopped_local"
    case fenceWait = "fence_wait"
    case recovering
    case unrecoverable
    case deleting
    case failed
    case cancelled
    case deleted

    public var isTerminal: Bool {
        switch self {
        case .failed, .cancelled, .deleted:
            true
        default:
            false
        }
    }

    public var acceptsUserWork: Bool {
        self == .ready || self == .executing
    }
}

public struct SandboxLifecycleEvent: Codable, Equatable, Sendable {
    public let from: SandboxLifecycleState
    public let to: SandboxLifecycleState
    public let occurredAt: Date
    public let reason: String

    public init(
        from: SandboxLifecycleState,
        to: SandboxLifecycleState,
        occurredAt: Date,
        reason: String
    ) {
        self.from = from
        self.to = to
        self.occurredAt = occurredAt
        self.reason = reason
    }
}

public enum SandboxLifecycleError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidTransition(from: SandboxLifecycleState, to: SandboxLifecycleState)
    case emptyReason
    case invalidSnapshot

    public var description: String {
        switch self {
        case .invalidTransition(let from, let to):
            return "invalid sandbox lifecycle transition \(from.rawValue) -> \(to.rawValue)"
        case .emptyReason:
            return "sandbox lifecycle transition reason must not be empty"
        case .invalidSnapshot:
            return "sandbox lifecycle snapshot is internally inconsistent"
        }
    }
}

public struct SandboxLifecycle: Codable, Equatable, Sendable {
    public private(set) var state: SandboxLifecycleState
    public private(set) var sequence: UInt64
    public private(set) var lastEvent: SandboxLifecycleEvent?

    public init() {
        self.state = .queued
        self.sequence = 0
        self.lastEvent = nil
    }

    public init(
        restoring state: SandboxLifecycleState,
        sequence: UInt64,
        lastEvent: SandboxLifecycleEvent?
    ) throws {
        guard Self.isConsistent(
            state: state,
            sequence: sequence,
            lastEvent: lastEvent
        ) else {
            throw SandboxLifecycleError.invalidSnapshot
        }
        self.state = state
        self.sequence = sequence
        self.lastEvent = lastEvent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            restoring: container.decode(SandboxLifecycleState.self, forKey: .state),
            sequence: container.decode(UInt64.self, forKey: .sequence),
            lastEvent: container.decodeIfPresent(
                SandboxLifecycleEvent.self,
                forKey: .lastEvent
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state, forKey: .state)
        try container.encode(sequence, forKey: .sequence)
        try container.encodeIfPresent(lastEvent, forKey: .lastEvent)
    }

    public func canTransition(to destination: SandboxLifecycleState) -> Bool {
        Self.allowedTransitions[state, default: []].contains(destination)
    }

    @discardableResult
    public mutating func transition(
        to destination: SandboxLifecycleState,
        reason: String,
        at date: Date = Date()
    ) throws -> SandboxLifecycleEvent {
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedReason.isEmpty else {
            throw SandboxLifecycleError.emptyReason
        }
        guard canTransition(to: destination) else {
            throw SandboxLifecycleError.invalidTransition(from: state, to: destination)
        }
        let event = SandboxLifecycleEvent(
            from: state,
            to: destination,
            occurredAt: date,
            reason: normalizedReason
        )
        state = destination
        sequence += 1
        lastEvent = event
        return event
    }

    private static let allowedTransitions: [SandboxLifecycleState: Set<SandboxLifecycleState>] = [
        .queued: [.reserving, .cancelled],
        .reserving: [.preparing, .failed, .cancelled],
        .preparing: [.booting, .failed, .stopping],
        .booting: [.ready, .failed, .stopping],
        .ready: [.executing, .stopping, .fenceWait],
        .executing: [.ready, .stopping, .fenceWait],
        .stopping: [.checkpointing, .deleting, .fenceWait],
        .checkpointing: [.stopped, .stoppedLocal],
        .stopped: [.preparing, .deleting],
        .stoppedLocal: [.checkpointing, .preparing, .recovering, .deleting],
        .fenceWait: [.stopping, .recovering],
        .recovering: [.stopped, .unrecoverable],
        .unrecoverable: [.deleting],
        .deleting: [.deleted],
        .failed: [],
        .cancelled: [],
        .deleted: [],
    ]

    private static func isConsistent(
        state: SandboxLifecycleState,
        sequence: UInt64,
        lastEvent: SandboxLifecycleEvent?
    ) -> Bool {
        if sequence == 0 {
            return state == .queued && lastEvent == nil
        }
        guard let lastEvent else {
            return false
        }
        let normalizedReason = lastEvent.reason.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return lastEvent.to == state
            && allowedTransitions[lastEvent.from, default: []].contains(lastEvent.to)
            && !normalizedReason.isEmpty
            && normalizedReason == lastEvent.reason
            && lastEvent.occurredAt.timeIntervalSinceReferenceDate.isFinite
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case sequence
        case lastEvent
    }
}
