import Foundation

enum MyMacLifecycle: String, CaseIterable, Equatable, Sendable {
    case serving
    case online
    case offline
    case neverSeen = "never_seen"
    case untrusted
    case unknown

    init(coordinatorValue: String) {
        self = Self(rawValue: coordinatorValue) ?? .unknown
    }

    var isOperationallyConnected: Bool {
        switch self {
        case .serving, .online:
            true
        case .offline, .neverSeen, .untrusted, .unknown:
            false
        }
    }
}

enum MyMacTrustLevel: Equatable, Sendable {
    case hardware
    case selfSigned
    case none
    case unknown(String?)

    init(coordinatorValue: String?) {
        switch coordinatorValue {
        case "hardware": self = .hardware
        case "self_signed": self = .selfSigned
        case "none": self = .none
        default: self = .unknown(coordinatorValue)
        }
    }
}

struct MyMacTrustSnapshot: Equatable, Sendable {
    var level: MyMacTrustLevel
    var attested: Bool?
    var appleDeviceAttestationVerified: Bool?
    var secureEnclaveKeyBound: Bool?
    var secureEnclaveAvailable: Bool?
    var runtimeVerified: Bool?
}

enum MyMacVersionDisposition: Equatable, Sendable {
    case current
    case updateAvailable
    case belowMinimum
    case unknown
}

struct MyMacVersionSnapshot: Equatable, Sendable {
    var installed: String?
    var latest: String?
    var minimum: String?
    var disposition: MyMacVersionDisposition

    init(installed: String?, latest: String?, minimum: String?) {
        self.installed = Self.normalized(installed)
        self.latest = Self.normalized(latest)
        self.minimum = Self.normalized(minimum)
        disposition = Self.disposition(
            installed: self.installed,
            latest: self.latest,
            minimum: self.minimum
        )
    }

    private static func disposition(
        installed: String?,
        latest: String?,
        minimum: String?
    ) -> MyMacVersionDisposition {
        guard let installed else { return .unknown }
        guard components(installed) != nil else { return .unknown }
        if let minimum {
            guard let comparison = compare(installed, minimum) else { return .unknown }
            if comparison == .orderedAscending {
                return .belowMinimum
            }
        }
        if let latest {
            guard let comparison = compare(installed, latest) else { return .unknown }
            if comparison == .orderedAscending {
                return .updateAvailable
            }
        }
        return latest != nil || minimum != nil ? .current : .unknown
    }

    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let lhs = components(lhs), let rhs = components(rhs) else { return nil }
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func components(_ value: String) -> [Int]? {
        var core = value
        if core.first == "v" || core.first == "V" {
            core.removeFirst()
        }
        core = String(core.split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? "")
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == parts.count ? numbers : nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

enum MyMacChallengeFreshness: Equatable, Sendable {
    case fresh
    case stale
    case awaitingFirstVerification
    case notApplicable
}

struct MyMacChallengeSnapshot: Equatable, Sendable {
    var lastVerifiedAt: Date?
    var failedAttempts: Int
    var maximumAge: TimeInterval
    var freshness: MyMacChallengeFreshness

    init(
        lastVerifiedAt: Date?,
        failedAttempts: Int,
        maximumAge: TimeInterval,
        lifecycle: MyMacLifecycle,
        asOf: Date
    ) {
        self.lastVerifiedAt = lastVerifiedAt
        self.failedAttempts = max(0, failedAttempts)
        self.maximumAge = max(0, maximumAge)

        guard lifecycle == .serving || lifecycle == .online else {
            freshness = .notApplicable
            return
        }
        guard let lastVerifiedAt else {
            freshness = .awaitingFirstVerification
            return
        }
        let age = max(0, asOf.timeIntervalSince(lastVerifiedAt))
        freshness = age > self.maximumAge ? .stale : .fresh
    }
}

struct MyMacHardwareSnapshot: Equatable, Sendable {
    var machineModel: String?
    var chipName: String?
    var chipFamily: String?
    var chipTier: String?
    var memoryGB: Int?
    var memoryAvailableGB: Double?
    var cpuCoreCount: Int?
    var performanceCoreCount: Int?
    var efficiencyCoreCount: Int?
    var gpuCoreCount: Int?
    var memoryBandwidthGBs: Double?
}

struct MyMacModelSnapshot: Equatable, Identifiable, Sendable {
    var id: String
    var sizeBytes: Int64?
    var modelType: String?
    var quantization: String?
    var isVision: Bool?
    var templateRenderOK: Bool?
}

enum MyMacBackendSlotState: Equatable, Sendable {
    case running
    case idle
    case idleShutdown
    case crashed
    case reloading
    case unknown(String)

    init(coordinatorValue: String) {
        switch coordinatorValue {
        case "running": self = .running
        case "idle": self = .idle
        case "idle_shutdown": self = .idleShutdown
        case "crashed": self = .crashed
        case "reloading": self = .reloading
        default: self = .unknown(coordinatorValue)
        }
    }
}

struct MyMacBackendSlotSnapshot: Equatable, Identifiable, Sendable {
    var modelID: String
    var state: MyMacBackendSlotState
    var runningRequestCount: Int?
    var waitingRequestCount: Int?
    var maximumConcurrency: Int?
    var activeTokens: Int64?
    var maximumPotentialTokens: Int64?
    var observedDecodeTPS: Double?
    var observedPrefillTPS: Double?
    var activeTokenBudgetUsed: Int64?
    var activeTokenBudgetMaximum: Int64?
    var queuedTokenBudget: Int64?
    var modelLoadTimeMS: Int64?

    var id: String { modelID }
}

struct MyMacBackendCapacitySnapshot: Equatable, Sendable {
    var slots: [MyMacBackendSlotSnapshot]
    var gpuMemoryActiveGB: Double?
    var gpuMemoryPeakGB: Double?
    var gpuMemoryCacheGB: Double?
    var totalMemoryGB: Double?
    var freeForLoadGB: Double?
}

struct MyMacLegacyCapacitySnapshot: Equatable, Sendable {
    var currentModelID: String?
    var warmModelIDs: [String]
}

/// Capacity authority is explicit: backend slots win whenever the coordinator
/// supplies them, even when a legacy `current_model` or `warm_models` value is
/// also present. Legacy fields are used only when backend capacity is absent.
enum MyMacCapacitySource: Equatable, Sendable {
    case backendSlots(MyMacBackendCapacitySnapshot)
    case legacy(MyMacLegacyCapacitySnapshot)
    case unavailable
}

struct MyMacSystemMetricsSnapshot: Equatable, Sendable {
    var memoryPressure: Double?
    var cpuUsage: Double?
    var thermalState: String?
}

struct MyMacLiveSnapshot: Equatable, Sendable {
    var lastHeartbeat: Date?
    var systemMetrics: MyMacSystemMetricsSnapshot?
    var capacity: MyMacCapacitySource
    var pendingRequests: Int?
    var maximumConcurrency: Int?
    var prefillTPS: Double?
    var decodeTPS: Double?
}
