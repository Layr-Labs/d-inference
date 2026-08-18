import Foundation

enum MyMacAttentionLevel: Int, Comparable, Equatable, Sendable {
    case none
    case notice
    case degraded
    case blocking

    static func < (lhs: MyMacAttentionLevel, rhs: MyMacAttentionLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum MyMacAttentionReason: String, Equatable, Sendable {
    case offline
    case neverSeen
    case untrusted
    case unknownLifecycle
    case runtimeNotVerified
    case trustBelowHardware
    case challengeAwaitingFirstVerification
    case challengeStale
    case challengeFailures
    case providerBelowMinimumVersion
    case providerUpdateAvailable
    case thermalFair
    case thermalSerious
    case thermalCritical
    case backendCrashed
    case backendCold
    case noCatalogModels
}

struct MyMacAttentionItem: Equatable, Identifiable, Sendable {
    var reason: MyMacAttentionReason
    var level: MyMacAttentionLevel

    var id: MyMacAttentionReason { reason }
}

struct MyMacAttentionSnapshot: Equatable, Sendable {
    /// Exact per-machine mirror of coordinator `needsAttention` used by
    /// `/v1/me/summary.counts.needs_attention`.
    var coordinatorItems: [MyMacAttentionItem]
    /// Additional live observations that can be useful without changing or
    /// attempting to locally reproduce the coordinator's aggregate count.
    var operationalNotices: [MyMacAttentionItem]

    var level: MyMacAttentionLevel {
        coordinatorItems.map(\.level).max() ?? .none
    }

    var operationalLevel: MyMacAttentionLevel {
        operationalNotices.map(\.level).max() ?? .none
    }

    var requiresAttention: Bool {
        !coordinatorItems.isEmpty
    }

    static func derive(
        lifecycle: MyMacLifecycle,
        trust: MyMacTrustSnapshot,
        version: MyMacVersionSnapshot,
        challenge: MyMacChallengeSnapshot,
        models: [MyMacModelSnapshot]?,
        live: MyMacLiveSnapshot?
    ) -> MyMacAttentionSnapshot {
        var coordinatorItems: [MyMacAttentionItem] = []
        var operationalNotices: [MyMacAttentionItem] = []

        switch lifecycle {
        case .offline:
            coordinatorItems.append(.init(reason: .offline, level: .blocking))
        case .neverSeen:
            coordinatorItems.append(.init(reason: .neverSeen, level: .blocking))
        case .untrusted:
            coordinatorItems.append(.init(reason: .untrusted, level: .blocking))
        case .unknown:
            operationalNotices.append(.init(reason: .unknownLifecycle, level: .notice))
        case .serving, .online:
            break
        }

        if trust.runtimeVerified == false {
            coordinatorItems.append(.init(reason: .runtimeNotVerified, level: .blocking))
        }

        if trust.level != .hardware {
            coordinatorItems.append(.init(reason: .trustBelowHardware, level: .blocking))
        }

        if lifecycle == .serving || lifecycle == .online {
            switch challenge.freshness {
            case .awaitingFirstVerification:
                operationalNotices.append(.init(
                    reason: .challengeAwaitingFirstVerification,
                    level: .notice
                ))
            case .stale:
                operationalNotices.append(.init(reason: .challengeStale, level: .notice))
            case .fresh, .notApplicable:
                break
            }
            if models?.isEmpty == true {
                operationalNotices.append(.init(reason: .noCatalogModels, level: .blocking))
            }
        }

        if challenge.failedAttempts > 0 {
            coordinatorItems.append(.init(
                reason: .challengeFailures,
                level: challenge.failedAttempts >= 3 ? .blocking : .notice
            ))
        }

        switch version.disposition {
        case .belowMinimum:
            coordinatorItems.append(.init(
                reason: .providerBelowMinimumVersion,
                level: .blocking
            ))
        case .updateAvailable:
            operationalNotices.append(.init(
                reason: .providerUpdateAvailable,
                level: .notice
            ))
        case .current, .unknown:
            break
        }

        switch live?.systemMetrics?.thermalState?.lowercased() {
        case "critical":
            operationalNotices.append(.init(reason: .thermalCritical, level: .blocking))
        case "serious":
            operationalNotices.append(.init(reason: .thermalSerious, level: .degraded))
        case "fair":
            operationalNotices.append(.init(reason: .thermalFair, level: .degraded))
        default:
            break
        }

        if case .backendSlots(let capacity) = live?.capacity {
            if capacity.slots.contains(where: { $0.state == .crashed }) {
                operationalNotices.append(.init(
                    reason: .backendCrashed,
                    level: .degraded
                ))
            }
            if capacity.slots.contains(where: { $0.state == .idleShutdown }) {
                operationalNotices.append(.init(reason: .backendCold, level: .degraded))
            }
        }

        return MyMacAttentionSnapshot(
            coordinatorItems: coordinatorItems,
            operationalNotices: operationalNotices
        )
    }
}
