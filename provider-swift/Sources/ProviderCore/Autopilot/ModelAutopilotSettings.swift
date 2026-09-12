import Foundation

/// Opt-in grants control over GPU residency of advertised, already cached builds.
/// It never grants permission to download new weights or remove disk files.
public struct ModelAutopilotSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var minDwellSeconds: UInt64
    public var pinnedModels: [String]

    public init(enabled: Bool = false, minDwellSeconds: UInt64 = 1_800, pinnedModels: [String] = []) {
        self.enabled = enabled
        self.minDwellSeconds = minDwellSeconds
        self.pinnedModels = pinnedModels
    }

    /// Bounds timer conversions even for a hand-edited configuration.
    public var effectiveMinDwellSeconds: Int {
        Int(min(86_400, max(60, minDwellSeconds)))
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case minDwellSeconds = "min_dwell_seconds"
        case pinnedModels = "pinned_models"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        minDwellSeconds = try c.decodeIfPresent(UInt64.self, forKey: .minDwellSeconds) ?? 1_800
        pinnedModels = try c.decodeIfPresent([String].self, forKey: .pinnedModels) ?? []
    }
}
