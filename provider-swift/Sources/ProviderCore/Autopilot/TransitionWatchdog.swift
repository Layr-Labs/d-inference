import Foundation

/// When each key was first observed in an unbroken run of observations. A key
/// missing from one observation starts again from its next appearance.
struct ContinuityClock<Key: Hashable & Sendable, Stamp: Sendable>: Sendable {
    private var firstSeen: [Key: Stamp] = [:]

    mutating func observe(_ keys: some Sequence<Key>, at stamp: Stamp) {
        let present = Set(keys)
        firstSeen = firstSeen.filter { present.contains($0.key) }
        for key in present where firstSeen[key] == nil { firstSeen[key] = stamp }
    }

    func since(_ key: Key) -> Stamp? { firstSeen[key] }
}

extension ModelAutopilotTransition {
    /// Far above the slowest healthy occurrence. Operations, loads, preloads
    /// and advertisements read or hash whole artifacts; the others are short
    /// bookkeeping spans.
    var stallBound: Duration {
        switch self {
        case .autopilotOperation, .startupPreload, .preload, .modelLoading, .modelAdvertisement, .modelSwitch:
            return .seconds(600)
        case .reslice, .reconnectAfterRetirement:
            return .seconds(300)
        }
    }
}

/// Ages each occurrence of a supervised transition and reports it once when
/// it first outlives its bound. Pure: the provider supplies observations and
/// the clock, and decides what a stall permits it to do.
struct TransitionWatchdog: Sendable {
    struct Occurrence: Hashable, Sendable {
        let transition: ModelAutopilotTransition
        /// The model or command, or "" for a provider-wide transition.
        let subject: String
        /// Separates successive occurrences with the same subject.
        let generation: String

        init(_ transition: ModelAutopilotTransition, subject: String = "", generation: String = "") {
            self.transition = transition
            self.subject = subject
            self.generation = generation
        }
    }

    struct Stall: Equatable, Sendable {
        let occurrence: Occurrence
        let age: Duration
    }

    private var ages = ContinuityClock<Occurrence, ContinuousClock.Instant>()
    private var stalled: Set<Occurrence> = []
    private var counts: [ModelAutopilotTransition: ModelAutopilotTransitionStall] = [:]

    /// Counts and returns the occurrences that exceed their bound for the
    /// first time, in transition declaration order.
    mutating func observe(_ active: Set<Occurrence>, now: ContinuousClock.Instant) -> [Stall] {
        ages.observe(active, at: now)
        stalled.formIntersection(active)
        let order = ModelAutopilotTransition.allCases
        let newlyStalled = active.subtracting(stalled).compactMap { occurrence -> Stall? in
            guard let since = ages.since(occurrence), now - since >= occurrence.transition.stallBound
            else { return nil }
            return Stall(occurrence: occurrence, age: now - since)
        }.sorted {
            (order.firstIndex(of: $0.occurrence.transition) ?? 0, $0.occurrence.subject, $0.occurrence.generation)
                < (order.firstIndex(of: $1.occurrence.transition) ?? 0, $1.occurrence.subject, $1.occurrence.generation)
        }
        // Counted in report order, so `last_age_ms` is deterministic when
        // several occurrences of one transition stall together.
        for stall in newlyStalled {
            stalled.insert(stall.occurrence)
            let transition = stall.occurrence.transition
            var record = counts[transition] ?? .init(transition: transition.rawValue, count: 0, lastAgeMs: 0)
            record.count &+= 1
            record.lastAgeMs = stall.age.autopilotMilliseconds
            counts[transition] = record
        }
        return newlyStalled
    }

    /// Forget current occurrences; cumulative stall counts remain.
    mutating func forgetOccurrences() {
        ages = ContinuityClock()
        stalled = []
    }

    /// Cumulative stalls for the wire, nil before the first one.
    var report: [ModelAutopilotTransitionStall]? {
        let records = ModelAutopilotTransition.allCases.compactMap { counts[$0] }
        return records.isEmpty ? nil : records
    }
}

extension Duration {
    /// Whole milliseconds, clamped at zero and saturating: the unit of every
    /// Autopilot wire timing.
    var autopilotMilliseconds: Int64 {
        guard self > .zero else { return 0 }
        let (seconds, attoseconds) = components
        let (milliseconds, overflow) = seconds.multipliedReportingOverflow(by: 1_000)
        let (total, sumOverflow) = milliseconds.addingReportingOverflow(attoseconds / 1_000_000_000_000_000)
        return overflow || sumOverflow ? .max : total
    }
}
