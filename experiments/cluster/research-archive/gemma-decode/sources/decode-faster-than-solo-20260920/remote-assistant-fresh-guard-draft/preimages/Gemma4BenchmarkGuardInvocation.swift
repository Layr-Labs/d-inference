import Foundation

/// CPU-only scope chronology. This carries no resource or process authority.
struct Gemma4BenchmarkGuardInvocation {
    static let schema = "gemma4_invocation_fresh_observation_v1"
    enum Consumer: Equatable { case entry, owner }
    enum Mode: Equatable { case entry, owner, combined }
    enum Failure: String, Error, CustomStringConvertible {
        case closed, invalidConfiguration, expired, wrongConsumer, staleObservation, incomplete
        var description: String { "Gemma guard invocation: " + rawValue }
    }
    private let mode: Mode, deadline: UInt64, created: UInt64, maximumAge: UInt64
    private var uses = 0, closed = false
    var expectedUses: Int { mode == .combined ? 3 : 1 }

    init(mode: Mode, deadline: UInt64, created: UInt64, maximumAge: UInt64) {
        self.mode = mode; self.deadline = deadline; self.created = created; self.maximumAge = maximumAge
    }
    private func current(expectedDeadline: UInt64, now: UInt64) throws {
        guard !closed else { throw Failure.closed }
        guard maximumAge > 0, deadline > created, expectedDeadline == deadline else {
            throw Failure.invalidConfiguration
        }
        guard now >= created, now < deadline, now-created <= maximumAge else { throw Failure.expired }
    }
    func preflight(_ consumer: Consumer, expectedDeadline: UInt64, now: UInt64) throws {
        try current(expectedDeadline: expectedDeadline, now: now)
        let expected: Consumer = mode == .owner || (mode == .combined && uses == 1) ? .owner : .entry
        guard uses < expectedUses, consumer == expected else { throw Failure.wrongConsumer }
    }
    mutating func accept(_ consumer: Consumer, started: UInt64, completed: UInt64,
                         expectedDeadline: UInt64, now: UInt64) throws {
        try preflight(consumer, expectedDeadline: expectedDeadline, now: now)
        guard started >= created, completed >= started, now >= completed,
              completed-started <= maximumAge, now-completed <= maximumAge else {
            throw Failure.staleObservation
        }
        uses += 1
    }
    mutating func finish(expectedDeadline: UInt64, now: UInt64) throws {
        try current(expectedDeadline: expectedDeadline, now: now)
        guard uses == expectedUses else { throw Failure.incomplete }
        close()
    }
    mutating func close() { closed = true }
}
