import Foundation

/// Codable records that mirror the account-scoped coordinator responses.
///
/// These records deliberately keep coordinator field names and optionality at
/// the boundary. They do not contain preview state or presentation decisions.
struct MyMacsCPUCoresWireRecord: Codable, Equatable, Sendable {
    var total: Int?
    var performance: Int?
    var efficiency: Int?
}

struct MyMacsHardwareWireRecord: Codable, Equatable, Sendable {
    var machineModel: String?
    var chipName: String?
    var chipFamily: String?
    var chipTier: String?
    var memoryGB: Int?
    var memoryAvailableGB: Double?
    var cpuCores: MyMacsCPUCoresWireRecord?
    var gpuCores: Int?
    var memoryBandwidthGBs: Double?

    enum CodingKeys: String, CodingKey {
        case machineModel = "machine_model"
        case chipName = "chip_name"
        case chipFamily = "chip_family"
        case chipTier = "chip_tier"
        case memoryGB = "memory_gb"
        case memoryAvailableGB = "memory_available_gb"
        case cpuCores = "cpu_cores"
        case gpuCores = "gpu_cores"
        case memoryBandwidthGBs = "memory_bandwidth_gbs"
    }
}

struct MyMacsModelWireRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var sizeBytes: Int64?
    var modelType: String?
    var quantization: String?
    var weightHash: String?
    var isVision: Bool?
    var templateRenderOK: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case sizeBytes = "size_bytes"
        case modelType = "model_type"
        case quantization
        case weightHash = "weight_hash"
        case isVision = "is_vision"
        case templateRenderOK = "template_render_ok"
    }
}

struct MyMacsSystemMetricsWireRecord: Codable, Equatable, Sendable {
    var memoryPressure: Double?
    var cpuUsage: Double?
    var thermalState: String?

    enum CodingKeys: String, CodingKey {
        case memoryPressure = "memory_pressure"
        case cpuUsage = "cpu_usage"
        case thermalState = "thermal_state"
    }
}

struct MyMacsBackendSlotWireRecord: Codable, Equatable, Identifiable, Sendable {
    var model: String
    var state: String
    var numRunning: Int?
    var numWaiting: Int?
    var maxConcurrency: Int?
    var activeTokens: Int64?
    var maxTokensPotential: Int64?
    var observedDecodeTPS: Double?
    var observedPrefillTPS: Double?
    var activeTokenBudgetUsed: Int64?
    var activeTokenBudgetMax: Int64?
    var queuedTokenBudget: Int64?
    var modelLoadTimeMS: Int64?

    var id: String { model }

    enum CodingKeys: String, CodingKey {
        case model
        case state
        case numRunning = "num_running"
        case numWaiting = "num_waiting"
        case maxConcurrency = "max_concurrency"
        case activeTokens = "active_tokens"
        case maxTokensPotential = "max_tokens_potential"
        case observedDecodeTPS = "observed_decode_tps"
        case observedPrefillTPS = "observed_prefill_tps"
        case activeTokenBudgetUsed = "active_token_budget_used"
        case activeTokenBudgetMax = "active_token_budget_max"
        case queuedTokenBudget = "queued_token_budget"
        case modelLoadTimeMS = "model_load_time_ms"
    }
}

struct MyMacsBackendCapacityWireRecord: Codable, Equatable, Sendable {
    var slots: [MyMacsBackendSlotWireRecord]
    var gpuMemoryActiveGB: Double?
    var gpuMemoryPeakGB: Double?
    var gpuMemoryCacheGB: Double?
    var totalMemoryGB: Double?
    var freeForLoadGB: Double?

    enum CodingKeys: String, CodingKey {
        case slots
        case gpuMemoryActiveGB = "gpu_memory_active_gb"
        case gpuMemoryPeakGB = "gpu_memory_peak_gb"
        case gpuMemoryCacheGB = "gpu_memory_cache_gb"
        case totalMemoryGB = "total_memory_gb"
        case freeForLoadGB = "free_for_load_gb"
    }
}

struct MyMacsReputationWireRecord: Codable, Equatable, Sendable {
    var score: Double?
    var totalJobs: Int?
    var successfulJobs: Int?
    var failedJobs: Int?
    var totalUptimeSeconds: Int64?
    var averageResponseTimeMS: Int64?
    var challengesPassed: Int?
    var challengesFailed: Int?

    enum CodingKeys: String, CodingKey {
        case score
        case totalJobs = "total_jobs"
        case successfulJobs = "successful_jobs"
        case failedJobs = "failed_jobs"
        case totalUptimeSeconds = "total_uptime_seconds"
        case averageResponseTimeMS = "avg_response_time_ms"
        case challengesPassed = "challenges_passed"
        case challengesFailed = "challenges_failed"
    }
}

struct MyMacsProviderWireRecord: Codable, Equatable, Sendable {
    /// Per-connection provider session identifier. This is not stable machine identity.
    var providerID: String
    var accountID: String?
    var status: String
    var online: Bool?
    var lastHeartbeat: Date?

    var hardware: MyMacsHardwareWireRecord?
    var models: [MyMacsModelWireRecord]?
    var backend: String?
    var version: String?
    var serialNumber: String?

    var trustLevel: String?
    var attested: Bool?
    var mdaVerified: Bool?
    var seKeyBound: Bool?
    var sePublicKey: String?
    /// Optional X25519 earnings-correlation key. It may be persisted and
    /// supplied for an offline machine, while older or minimal records omit it.
    var providerKey: String?
    var secureEnclave: Bool?
    var sipEnabled: Bool?
    var secureBootEnabled: Bool?
    var authenticatedRootEnabled: Bool?

    var runtimeVerified: Bool?
    var lastChallengeVerified: Date?
    var failedChallenges: Int?

    var systemMetrics: MyMacsSystemMetricsWireRecord?
    var backendCapacity: MyMacsBackendCapacityWireRecord?
    var warmModels: [String]?
    var currentModel: String?
    var pendingRequests: Int?
    var maxConcurrency: Int?
    var prefillTPS: Double?
    var decodeTPS: Double?

    var reputation: MyMacsReputationWireRecord?
    var lifetimeRequestsServed: Int64?
    var lifetimeTokensGenerated: Int64?
    var registeredAt: Date?
    var lastSeen: Date?

    enum CodingKeys: String, CodingKey {
        case providerID = "id"
        case accountID = "account_id"
        case status
        case online
        case lastHeartbeat = "last_heartbeat"
        case hardware
        case models
        case backend
        case version
        case serialNumber = "serial_number"
        case trustLevel = "trust_level"
        case attested
        case mdaVerified = "mda_verified"
        case seKeyBound = "se_key_bound"
        case sePublicKey = "se_public_key"
        case providerKey = "provider_key"
        case secureEnclave = "secure_enclave"
        case sipEnabled = "sip_enabled"
        case secureBootEnabled = "secure_boot_enabled"
        case authenticatedRootEnabled = "authenticated_root_enabled"
        case runtimeVerified = "runtime_verified"
        case lastChallengeVerified = "last_challenge_verified"
        case failedChallenges = "failed_challenges"
        case systemMetrics = "system_metrics"
        case backendCapacity = "backend_capacity"
        case warmModels = "warm_models"
        case currentModel = "current_model"
        case pendingRequests = "pending_requests"
        case maxConcurrency = "max_concurrency"
        case prefillTPS = "prefill_tps"
        case decodeTPS = "decode_tps"
        case reputation
        case lifetimeRequestsServed = "lifetime_requests_served"
        case lifetimeTokensGenerated = "lifetime_tokens_generated"
        case registeredAt = "registered_at"
        case lastSeen = "last_seen"
    }
}

struct MyMacsProvidersWireResponse: Codable, Equatable, Sendable {
    var providers: [MyMacsProviderWireRecord]
    var latestProviderVersion: String
    var minimumProviderVersion: String
    var heartbeatTimeoutSeconds: Int
    var challengeMaxAgeSeconds: Int

    enum CodingKeys: String, CodingKey {
        case providers
        case latestProviderVersion = "latest_provider_version"
        case minimumProviderVersion = "min_provider_version"
        case heartbeatTimeoutSeconds = "heartbeat_timeout_seconds"
        case challengeMaxAgeSeconds = "challenge_max_age_seconds"
    }
}

struct MyMacsFleetCountsWireRecord: Codable, Equatable, Sendable {
    var total: Int
    var online: Int
    var serving: Int
    var offline: Int
    var untrusted: Int
    var hardware: Int
    var needsAttention: Int

    enum CodingKeys: String, CodingKey {
        case total
        case online
        case serving
        case offline
        case untrusted
        case hardware
        case needsAttention = "needs_attention"
    }
}

struct MyMacsSummaryWireResponse: Codable, Equatable, Sendable {
    var accountID: String
    var availableBalanceMicroUSD: Int64
    var withdrawableBalanceMicroUSD: Int64
    var payoutReady: Bool
    var lifetimeMicroUSD: Int64
    var lifetimeJobs: Int64
    var last24hMicroUSD: Int64
    var last24hJobs: Int64
    var last7dMicroUSD: Int64
    var last7dJobs: Int64
    var counts: MyMacsFleetCountsWireRecord
    var latestProviderVersion: String
    var minimumProviderVersion: String

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case availableBalanceMicroUSD = "available_balance_micro_usd"
        case withdrawableBalanceMicroUSD = "withdrawable_balance_micro_usd"
        case payoutReady = "payout_ready"
        case lifetimeMicroUSD = "lifetime_micro_usd"
        case lifetimeJobs = "lifetime_jobs"
        case last24hMicroUSD = "last_24h_micro_usd"
        case last24hJobs = "last_24h_jobs"
        case last7dMicroUSD = "last_7d_micro_usd"
        case last7dJobs = "last_7d_jobs"
        case counts
        case latestProviderVersion = "latest_provider_version"
        case minimumProviderVersion = "min_provider_version"
    }
}
