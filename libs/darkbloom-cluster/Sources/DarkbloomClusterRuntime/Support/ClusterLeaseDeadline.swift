import Foundation

/// The deadline of a renewable rank lease (S03): where a worker process ends
/// unless its owner renews it. It replaces a fixed process lifetime. The
/// worker arms `ProcessDeadline` on it before any weights load, and its control
/// reader moves it forward on every `extendDeadline` line; the deadline thread
/// reads it at least once a second. Times are on the
/// `DispatchTime.now().uptimeNanoseconds` clock of this Mac.
public final class ClusterLeaseDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64
    private var renewalsValue: UInt64 = 0

    public init(uptimeNanoseconds: UInt64) { value = uptimeNanoseconds }

    /// The current deadline.
    public var uptimeNanoseconds: UInt64 { lock.withLock { value } }
    /// How many renewals moved it, for the log.
    public var renewals: UInt64 { lock.withLock { renewalsValue } }

    /// Moves the deadline to `ttl` after `now`. A renewal never shortens the
    /// lease: a late or reordered renewal leaves a later deadline in place.
    @discardableResult
    public func renew(now: UInt64, ttl: UInt64) -> UInt64 {
        let proposed = now.addingReportingOverflow(ttl)
        return lock.withLock {
            if !proposed.overflow && proposed.partialValue > value { value = proposed.partialValue }
            renewalsValue += 1
            return value
        }
    }
}
