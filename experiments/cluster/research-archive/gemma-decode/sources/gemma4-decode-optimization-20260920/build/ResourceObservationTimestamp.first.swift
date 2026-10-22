import Foundation

/// Reuse formatter setup, never the observation or its wall-clock value.
/// The lock confines Foundation's mutable formatter to one caller at a time.
enum ResourceObservationTimestamp {
    private static let lock = NSLock()
    private static let formatter = ISO8601DateFormatter()

    static func utc(_ date: Date = Date()) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }
}
