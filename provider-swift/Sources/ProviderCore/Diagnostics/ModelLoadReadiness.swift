import Foundation

/// The provider's live, no-eviction load equation for one cold model.
/// Numeric inputs come from the scanner and one capacity snapshot; callers
/// must withhold a verdict when any input is unavailable or stale.
public struct ModelLoadReadiness: Sendable, Equatable {
    public let estimatedMemoryGb: Double
    public let headroomGb: Double
    public let requiredGb: Double
    public let usableGb: Double
    public let shortfallGb: Double

    public init?(estimatedMemoryGb: Double, headroomGb: Double, usableGb: Double) {
        guard estimatedMemoryGb.isFinite, estimatedMemoryGb > 0,
              headroomGb.isFinite, headroomGb >= 0,
              usableGb.isFinite, usableGb >= 0 else { return nil }
        let required = estimatedMemoryGb + headroomGb
        guard required.isFinite else { return nil }
        self.estimatedMemoryGb = estimatedMemoryGb
        self.headroomGb = headroomGb
        self.requiredGb = required
        self.usableGb = usableGb
        self.shortfallGb = max(0, required - usableGb)
    }

    public var canLoadNow: Bool { shortfallGb == 0 }
}
