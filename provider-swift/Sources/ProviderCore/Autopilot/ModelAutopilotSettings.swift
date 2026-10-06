import Foundation

/// Opt-in grants control over GPU residency of advertised, already cached builds.
/// It never grants permission to download new weights or remove disk files.
public struct ModelAutopilotSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var consentRecorded: Bool
    public var paused: Bool
    public var selectedModels: [String]
    public var revision: String
    public var minIdleSeconds: UInt64
    public var minDwellSeconds: UInt64
    public var pinnedModels: [String]

    public init(enabled: Bool = false, minDwellSeconds: UInt64 = 1_800, pinnedModels: [String] = [],
                consentRecorded: Bool = false, paused: Bool = false, selectedModels: [String] = [],
                revision: String = "", minIdleSeconds: UInt64 = 60) {
        self.enabled = enabled
        self.consentRecorded = consentRecorded
        self.paused = paused
        self.selectedModels = selectedModels
        self.revision = revision
        self.minIdleSeconds = minIdleSeconds
        self.minDwellSeconds = minDwellSeconds
        self.pinnedModels = pinnedModels
    }

    public var hasConsent: Bool {
        enabled && consentRecorded && !revision.isEmpty && !selectedModels.isEmpty
            && selectedModels.count <= 256 && selectedModels.allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 }
    }

    public func allows(_ model: String) -> Bool { hasConsent && selectedModels.contains(model) }
    public var effectiveMinIdleSeconds: Int { Int(min(86_400, max(1, minIdleSeconds))) }

    /// Bounds timer conversions even for a hand-edited configuration.
    public var effectiveMinDwellSeconds: Int {
        Int(min(86_400, max(60, minDwellSeconds)))
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case consentRecorded = "consent_recorded", paused
        case selectedModels = "selected_models", revision
        case minIdleSeconds = "min_idle_seconds"
        case minDwellSeconds = "min_dwell_seconds"
        case pinnedModels = "pinned_models"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        consentRecorded = try c.decodeIfPresent(Bool.self, forKey: .consentRecorded) ?? false
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        selectedModels = try c.decodeIfPresent([String].self, forKey: .selectedModels) ?? []
        revision = try c.decodeIfPresent(String.self, forKey: .revision) ?? ""
        minIdleSeconds = try c.decodeIfPresent(UInt64.self, forKey: .minIdleSeconds) ?? 60
        minDwellSeconds = try c.decodeIfPresent(UInt64.self, forKey: .minDwellSeconds) ?? 1_800
        pinnedModels = try c.decodeIfPresent([String].self, forKey: .pinnedModels) ?? []
        // Older experimental configuration cannot silently grant the new
        // selected-model contract or prevent ordinary serving after upgrade.
        if !hasConsent { enabled = false }
    }
}
