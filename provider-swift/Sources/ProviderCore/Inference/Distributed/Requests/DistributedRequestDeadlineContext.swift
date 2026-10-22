import Foundation

/// Provider-local monotonic deadlines. Neither instant is a wall timestamp or a
/// remotely transferable uptime value. A remote owner receives remaining durations
/// and derives its own local deadlines; the originating provider still enforces these.
public struct DistributedRequestDeadlineContext: Sendable, Equatable {
    public let generationDeadline: ContinuousClock.Instant
    public let firstTokenDeadline: ContinuousClock.Instant?

    public init(generationDeadline: ContinuousClock.Instant,
                firstTokenDeadline: ContinuousClock.Instant? = nil) {
        self.generationDeadline = generationDeadline
        self.firstTokenDeadline = firstTokenDeadline
    }

    /// Additional policy can shorten either deadline, never replenish it.
    public func restricted(to other: Self) -> Self {
        let first = [firstTokenDeadline, other.firstTokenDeadline].compactMap { $0 }.min()
        return .init(generationDeadline: min(generationDeadline, other.generationDeadline),
                     firstTokenDeadline: first)
    }

    func checkAdmission(at now: ContinuousClock.Instant) throws {
        guard now < generationDeadline else { throw DistributedRequestDeadlineError.generationExpired }
        if let firstTokenDeadline, now >= firstTokenDeadline {
            throw DistributedRequestDeadlineError.firstTokenExpired
        }
    }

    /// Sample local uptime BEFORE `now`. This conservatively charges sampling
    /// overhead instead of adding it to the request allowance. Conversion is only
    /// for this Mac's children; ContinuousClock remains the origin's authority.
    func localDeadlines(at now: ContinuousClock.Instant, uptimeBeforeNow: UInt64,
                        maximumRemaining: Duration, lifetimeDeadline: UInt64) throws -> DistributedLocalRequestDeadlines {
        try checkAdmission(at: now)
        guard lifetimeDeadline > uptimeBeforeNow else { throw DistributedRequestDeadlineError.workerLifetimeExpired }
        let remaining = min(now.duration(to: generationDeadline), maximumRemaining)
        let amount = try Self.wholeNanoseconds(remaining)
        let end = uptimeBeforeNow.addingReportingOverflow(amount)
        guard !end.overflow else { throw DistributedRequestDeadlineError.uptimeOverflow }
        let generation = min(end.partialValue, lifetimeDeadline)
        let admission: UInt64
        if let firstTokenDeadline {
            let first = try Self.wholeNanoseconds(min(now.duration(to: firstTokenDeadline), remaining))
            // first <= amount; the checked generation addition also bounds this.
            admission = min(uptimeBeforeNow + first, generation)
        } else { admission = generation }
        return .init(generation: generation, admission: admission)
    }

    private static func wholeNanoseconds(_ duration: Duration) throws -> UInt64 {
        guard duration > .zero else { throw DistributedRequestDeadlineError.invalidRemainingDuration }
        let parts = duration.components
        let seconds = parts.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !seconds.overflow else { throw DistributedRequestDeadlineError.invalidRemainingDuration }
        let value = seconds.partialValue.addingReportingOverflow(parts.attoseconds / 1_000_000_000)
        guard !value.overflow, value.partialValue > 0 else { throw DistributedRequestDeadlineError.invalidRemainingDuration }
        // Floor to complete nanoseconds: subnanosecond remainder grants no time.
        return UInt64(value.partialValue)
    }
}

struct DistributedLocalRequestDeadlines: Sendable, Equatable {
    let generation: UInt64
    let admission: UInt64
}

public enum DistributedRequestDeadlineError: Error, Sendable, Equatable {
    case generationExpired
    case firstTokenExpired
    case workerLifetimeExpired
    case invalidRemainingDuration
    case uptimeOverflow
}
