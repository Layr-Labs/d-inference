import Foundation
import ProviderCore

/// Capture membership and deadline at the same instant before model hashing.
/// A nil end means continuous availability, never an already-closed window.
struct ScheduledWindowTiming {
    let end: Date?

    init?(schedule: Schedule, at start: Date) {
        guard schedule.isActive(at: start) else { return nil }
        end = schedule.durationUntilInactive(from: start).map { start.addingTimeInterval($0) }
    }
}
