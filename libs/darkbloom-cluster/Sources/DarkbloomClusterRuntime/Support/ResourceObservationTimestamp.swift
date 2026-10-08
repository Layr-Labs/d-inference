import Foundation

/// Reuse formatter setup, never the observation or its wall-clock value.
/// The lock confines Foundation's mutable formatter to one caller at a time.
enum ResourceObservationTimestamp {
    // Foundation does not mark ISO8601DateFormatter Sendable. Its complete
    // mutable state is private to this holder; every use holds the same lock.
    private final class LockedFormatter: @unchecked Sendable {
        private let lock = NSLock()
        private let formatter = ISO8601DateFormatter()

        func string(from date: Date) -> String {
            lock.lock()
            defer { lock.unlock() }
            return formatter.string(from: date)
        }
    }
    private static let shared = LockedFormatter()

    static func utc(_ date: Date = Date()) -> String {
        shared.string(from: date)
    }
}
