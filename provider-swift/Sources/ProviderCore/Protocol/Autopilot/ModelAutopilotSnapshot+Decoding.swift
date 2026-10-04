import Foundation

// The wire codec uses explicit snake_case CodingKeys. DaemonStateFile also
// decodes these snapshots, but its convertFromSnakeCase strategy has already
// transformed those keys. Accept either projection without defaulting missing
// required fields or changing the synthesized wire encoder.
extension ModelAutopilotSnapshot {
    public init(from decoder: Decoder) throws {
        let c = try AutopilotSnapshotDecoder<CodingKeys>(decoder)
        protocolVersion = try c.required(Int.self, .protocolVersion)
        active = try c.required(Bool.self, .active)
        observeOnly = try c.required(Bool.self, .observeOnly)
        paused = try c.required(Bool.self, .paused)
        sessionId = try c.optional(String.self, .sessionId)
        revision = try c.required(String.self, .revision)
        selectedModels = try c.required([String].self, .selectedModels)
        minIdleSeconds = try c.required(Int.self, .minIdleSeconds)
        loadHistory = try c.optional([ModelAutopilotLoadTiming].self, .loadHistory)
        lastElapsedMs = try c.optional(Int64.self, .lastElapsedMs)
        lastReleaseMs = try c.optional(Int64.self, .lastReleaseMs)
        lastLoadMs = try c.optional(Int64.self, .lastLoadMs)
        enabled = try c.required(Bool.self, .enabled)
        cachedOnly = try c.required(Bool.self, .cachedOnly)
        minDwellSeconds = try c.required(Int.self, .minDwellSeconds)
        pinnedModels = try c.required([String].self, .pinnedModels)
        maxModelSlots = try c.required(Int.self, .maxModelSlots)
        residentModels = try c.required([ModelAutopilotResident].self, .residentModels)
        freeForLoadNoEvictGb = try c.optional(Double.self, .freeForLoadNoEvictGb)
        activeCommandId = try c.optional(String.self, .activeCommandId)
        lastCommandId = try c.optional(String.self, .lastCommandId)
        lastCommandStatus = try c.optional(ModelAutopilotStatus.State.self, .lastCommandStatus)
    }
}

extension ModelAutopilotResident {
    public init(from decoder: Decoder) throws {
        let c = try AutopilotSnapshotDecoder<CodingKeys>(decoder)
        modelId = try c.required(String.self, .modelId)
        residentSeconds = try c.required(Int.self, .residentSeconds)
        idleSeconds = try c.required(Int.self, .idleSeconds)
        weightsGb = try c.required(Double.self, .weightsGb)
        residentGb = try c.optional(Double.self, .residentGb)
    }
}

extension ModelAutopilotLoadTiming {
    public init(from decoder: Decoder) throws {
        let c = try AutopilotSnapshotDecoder<CodingKeys>(decoder)
        modelId = try c.required(String.self, .modelId)
        loadMs = try c.required(Int64.self, .loadMs)
        measuredAtMs = try c.required(Int64.self, .measuredAtMs)
        weightHash = try c.required(String.self, .weightHash)
    }
}

/// Scoped to the snapshot's known lower-case snake_case keys. This is not a
/// replacement key strategy for the other protocol or daemon-state types.
private struct AutopilotSnapshotDecoder<Key: CodingKey> {
    private struct ProjectedKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private let values: KeyedDecodingContainer<ProjectedKey>

    init(_ decoder: Decoder) throws {
        values = try decoder.container(keyedBy: ProjectedKey.self)
    }

    private func projected(_ key: Key) -> ProjectedKey {
        let wire = ProjectedKey(stringValue: key.stringValue)
        if values.contains(wire) { return wire }
        let parts = key.stringValue.split(separator: "_")
        let camel = String(parts.first ?? "") + parts.dropFirst().map { $0.capitalized }.joined()
        return ProjectedKey(stringValue: camel)
    }

    func required<Value: Decodable>(_ type: Value.Type, _ key: Key) throws -> Value {
        try values.decode(type, forKey: projected(key))
    }

    func optional<Value: Decodable>(_ type: Value.Type, _ key: Key) throws -> Value? {
        try values.decodeIfPresent(type, forKey: projected(key))
    }
}
