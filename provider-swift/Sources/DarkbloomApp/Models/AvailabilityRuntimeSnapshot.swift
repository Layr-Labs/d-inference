import Foundation

enum AvailabilityRuntimeState: String, Codable, Equatable, Sendable {
    case available
    case serving
    case paused
    case scheduledOff = "scheduled-off"
    case attention
    case stale
    case starting
    case stopping
    case restarting
}

/// A local observation of the provider process. Persistent scheduling windows,
/// idle-unload preferences, and timezone never come from this type.
struct AvailabilityRuntimeSnapshot: Codable, Equatable, Sendable {
    var sampledAt: Date
    var sourceUpdatedAt: Date
    var state: AvailabilityRuntimeState
    var nextObservedTransitionAt: Date?
    var unifiedLocalEndpointIsReachable: Bool?

    init(
        sampledAt: Date,
        sourceUpdatedAt: Date,
        state: AvailabilityRuntimeState,
        nextObservedTransitionAt: Date? = nil,
        unifiedLocalEndpointIsReachable: Bool? = nil
    ) {
        self.sampledAt = sampledAt
        self.sourceUpdatedAt = sourceUpdatedAt
        self.state = state
        self.nextObservedTransitionAt = nextObservedTransitionAt
        self.unifiedLocalEndpointIsReachable = unifiedLocalEndpointIsReachable
    }

    /// Adapts only runtime observations. It intentionally ignores the provider
    /// snapshot's human-readable availability summary and never reconstructs a
    /// schedule or policy from coordinator-facing state.
    init(providerSnapshot: ProviderSnapshot) {
        sampledAt = providerSnapshot.sampledAt
        sourceUpdatedAt = providerSnapshot.sourceUpdatedAt
        state = AvailabilityRuntimeState(providerRunState: providerSnapshot.runState)
        nextObservedTransitionAt = providerSnapshot.availability.nextChangeAt
        unifiedLocalEndpointIsReachable = providerSnapshot.localEndpoint?.isReachable
    }

    var isStale: Bool {
        state == .stale || sampledAt.timeIntervalSince(sourceUpdatedAt) > 90
    }
}

private extension AvailabilityRuntimeState {
    init(providerRunState: ProviderRunState) {
        switch providerRunState {
        case .online: self = .available
        case .serving: self = .serving
        case .paused: self = .paused
        case .scheduledOff: self = .scheduledOff
        case .attention: self = .attention
        case .stale: self = .stale
        case .starting: self = .starting
        case .stopping: self = .stopping
        case .restarting: self = .restarting
        }
    }
}

enum AvailabilityLocalAPIBehavior: String, CaseIterable, Hashable, Sendable {
    /// `darkbloom start --local-endpoint` lives inside the scheduled provider
    /// loop, so it starts and stops with network availability windows.
    case unifiedEndpointFollowsSchedule
    /// `darkbloom start --local` runs its own standalone server and is not
    /// controlled by the network provider's schedule.
    case standaloneLocalIsIndependent
}
