import Foundation

/// Protocol 1 is cached-only. Absent snapshot means no consent; neither an empty
/// enabled_models allowlist nor an advertised build implies opt-in.
public struct ModelAutopilotSnapshot: Codable, Sendable, Equatable {
    public var protocolVersion: Int = 1
    public var enabled: Bool
    public var cachedOnly: Bool = true
    public var minDwellSeconds: Int
    public var pinnedModels: [String]
    public var maxModelSlots: Int
    public var residentModels: [ModelAutopilotResident]
    /// Weight-only headroom while retaining ALL residents, from the load gate.
    public var freeForLoadNoEvictGb: Double?
    public var activeCommandId: String?
    public var lastCommandId: String?
    public var lastCommandStatus: ModelAutopilotStatus.State?

    public init(enabled: Bool, minDwellSeconds: Int = 1_800, pinnedModels: [String] = [],
                maxModelSlots: Int = 1, residentModels: [ModelAutopilotResident] = [],
                freeForLoadNoEvictGb: Double? = nil, activeCommandId: String? = nil,
                lastCommandId: String? = nil, lastCommandStatus: ModelAutopilotStatus.State? = nil) {
        self.enabled = enabled
        self.minDwellSeconds = minDwellSeconds
        self.pinnedModels = pinnedModels
        self.maxModelSlots = maxModelSlots
        self.residentModels = residentModels
        self.freeForLoadNoEvictGb = freeForLoadNoEvictGb
        self.activeCommandId = activeCommandId
        self.lastCommandId = lastCommandId
        self.lastCommandStatus = lastCommandStatus
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol", enabled
        case cachedOnly = "cached_only", minDwellSeconds = "min_dwell_seconds"
        case pinnedModels = "pinned_models", maxModelSlots = "max_model_slots"
        case residentModels = "resident_models", freeForLoadNoEvictGb = "free_for_load_no_evict_gb"
        case activeCommandId = "active_command_id", lastCommandId = "last_command_id"
        case lastCommandStatus = "last_command_status"
    }
}

public struct ModelAutopilotResident: Codable, Sendable, Equatable {
    public var modelId: String
    public var residentSeconds: Int
    public var idleSeconds: Int
    /// Scanner-padded load estimate; NOT extra free memory or throughput.
    public var weightsGb: Double
    /// Actual slot weight ownership in GiB, the only victim reclaim credit.
    public var residentGb: Double?
    public init(modelId: String, residentSeconds: Int, idleSeconds: Int, weightsGb: Double,
                residentGb: Double? = nil) {
        self.modelId = modelId
        self.residentSeconds = residentSeconds
        self.idleSeconds = idleSeconds
        self.weightsGb = weightsGb
        self.residentGb = residentGb
    }
    enum CodingKeys: String, CodingKey {
        case modelId = "model_id", residentSeconds = "resident_seconds"
        case idleSeconds = "idle_seconds", weightsGb = "weights_gb"
        case residentGb = "resident_gb"
    }
}

public struct ModelAutopilotCommand: Codable, Sendable, Equatable {
    public var commandId: String
    public var loadModelId: String?
    public var unloadModelIds: [String]
    public var expectedResidentModels: [String]
    public var expiresAtMs: Int64
    public var leaseSeconds: Int

    public init(commandId: String, loadModelId: String? = nil, unloadModelIds: [String] = [],
                expectedResidentModels: [String] = [], expiresAtMs: Int64, leaseSeconds: Int = 1_800) {
        self.commandId = commandId
        self.loadModelId = loadModelId
        self.unloadModelIds = unloadModelIds
        self.expectedResidentModels = expectedResidentModels
        self.expiresAtMs = expiresAtMs
        self.leaseSeconds = leaseSeconds
    }
    enum CodingKeys: String, CodingKey {
        case commandId = "command_id", loadModelId = "load_model_id"
        case unloadModelIds = "unload_model_ids", expectedResidentModels = "expected_resident_models"
        case expiresAtMs = "expires_at_ms", leaseSeconds = "lease_seconds"
    }
}

public struct ModelAutopilotStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case started, succeeded, failed }
    public var commandId: String
    public var status: State
    public var error: String?
    public var modelAutopilot: ModelAutopilotSnapshot
    public init(commandId: String, status: State, error: String? = nil, modelAutopilot: ModelAutopilotSnapshot) {
        self.commandId = commandId
        self.status = status
        self.error = error
        self.modelAutopilot = modelAutopilot
    }
    enum CodingKeys: String, CodingKey {
        case commandId = "command_id", status, error
        case modelAutopilot = "model_autopilot"
    }
}
