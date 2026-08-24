import Foundation

enum ProviderRunState: String, CaseIterable, Codable, Sendable {
    case online
    case serving
    case paused
    case scheduledOff = "scheduled-off"
    case attention
    case stale
    case starting
    case stopping
    case restarting

    var isTransitioning: Bool {
        switch self {
        case .starting, .stopping, .restarting: true
        case .online, .serving, .paused, .scheduledOff, .attention, .stale: false
        }
    }
}

enum ProviderTrustState: String, Codable, Sendable {
    case verified
    case pending
    case failed
    case unknown
}

struct ProviderTrustSnapshot: Codable, Equatable, Sendable {
    var state: ProviderTrustState
    var level: String
    var reason: String
    var guidance: String?
    var updatedAt: Date?
}

enum ProviderAvailabilityState: String, Codable, Sendable {
    case alwaysAvailable = "always-available"
    case scheduledActive = "scheduled-active"
    case scheduledOff = "scheduled-off"
    case paused
}

struct ProviderAvailabilitySnapshot: Codable, Equatable, Sendable {
    var state: ProviderAvailabilityState
    var summary: String
    var nextChangeAt: Date?
}

struct ProviderActivitySnapshot: Codable, Equatable, Sendable {
    var requestsServed: UInt64
    var tokensGenerated: UInt64
    var usageGaps: UInt64
}

struct ProviderCapacitySnapshot: Codable, Equatable, Sendable {
    var totalMemoryGB: Double
    var gpuMemoryActiveGB: Double
    var gpuMemoryCacheGB: Double?

    var usedMemoryGB: Double {
        max(0, gpuMemoryActiveGB + (gpuMemoryCacheGB ?? 0))
    }

    var usedFraction: Double {
        guard totalMemoryGB > 0 else { return 0 }
        return min(1, usedMemoryGB / totalMemoryGB)
    }
}

struct ProviderModelSummary: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var displayName: String
    var sizeGB: Double?
    var isVision: Bool
}

enum ProviderProblemSeverity: String, Codable, Sendable {
    case notice
    case warning
    case critical
}

struct ProviderProblem: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var severity: ProviderProblemSeverity
    var title: String
    var detail: String
    var recoveryTitle: String?
}

struct ProviderLocalEndpointSnapshot: Codable, Equatable, Sendable {
    var baseURL: URL
    var requiresAuthentication: Bool
    var isReachable: Bool
}

struct ProviderConnectivitySnapshot: Codable, Equatable, Sendable {
    var reconnectCount: Int
    var lastError: String?
}

struct ProviderSystemSnapshot: Codable, Equatable, Sendable {
    var memoryPressure: Double
    var cpuUsage: Double
    var thermalState: String
}

struct ProviderSnapshot: Codable, Equatable, Sendable {
    var sampledAt: Date
    var sourceUpdatedAt: Date
    var runState: ProviderRunState
    var providerName: String
    var version: String
    var pid: Int32?
    var startedAt: Date?
    var trust: ProviderTrustSnapshot
    var availability: ProviderAvailabilitySnapshot
    var activity: ProviderActivitySnapshot
    var capacity: ProviderCapacitySnapshot?
    var currentModel: ProviderModelSummary?
    var warmModels: [ProviderModelSummary]
    var lastProblem: ProviderProblem?
    var localEndpoint: ProviderLocalEndpointSnapshot?
    var connectivity: ProviderConnectivitySnapshot?
    var system: ProviderSystemSnapshot?

    var uptime: TimeInterval? {
        guard let startedAt else { return nil }
        return max(0, sampledAt.timeIntervalSince(startedAt))
    }

    var freshnessAge: TimeInterval {
        max(0, sampledAt.timeIntervalSince(sourceUpdatedAt))
    }

    var isStale: Bool {
        runState == .stale || freshnessAge > 90
    }

    var isServing: Bool {
        runState == .serving
    }

    var isRunning: Bool {
        switch runState {
        case .online, .serving, .attention, .starting, .stopping, .restarting:
            true
        case .paused, .scheduledOff, .stale:
            false
        }
    }
}
