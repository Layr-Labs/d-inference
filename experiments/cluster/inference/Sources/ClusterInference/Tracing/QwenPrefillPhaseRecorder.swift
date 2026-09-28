import Foundation
import Dispatch

/// Optional caller-owned CPU observer. Never creates a clock observation in
/// init/begin/seal/fail. Only observe() reads time. The existing request owner
/// must call fail on every error and seal only after constructing its successful
/// CPU result and verifying clean request retirement/native error state.
///
/// The outer caller retrieves successfulTrace() only AFTER its outer model
/// owner returns successfully; request success does not prove model release.
final class QwenPrefillPhaseRecorder {
    typealias Clock = () throws -> UInt64
    private enum State: Equatable { case fresh, active, sealed, failed }

    let identity: QwenPrefillPhaseIdentity
    let maximumEvents: Int
    private let clock: Clock
    private let clockSource: QwenPrefillPhaseClockSource
    private let lock = NSRecursiveLock()
    private var state = State.fresh
    private var readingClock = false
    private var events: [QwenPrefillPhaseEvent] = []
    private var result: QwenPrefillPhaseTrace?

    convenience init(identity: QwenPrefillPhaseIdentity, maximumEvents: Int = 512) throws {
        try self.init(identity: identity, maximumEvents: maximumEvents,
            clockSource: .dispatchUptimeNanoseconds, clock: { DispatchTime.now().uptimeNanoseconds })
    }

    /// Test-only injection is visibly distinguished in the returned trace.
    convenience init(identity: QwenPrefillPhaseIdentity, maximumEvents: Int = 512,
                     testClock: @escaping Clock) throws {
        try self.init(identity: identity, maximumEvents: maximumEvents,
            clockSource: .injectedTestClock, clock: testClock)
    }

    private init(identity: QwenPrefillPhaseIdentity, maximumEvents: Int,
                 clockSource: QwenPrefillPhaseClockSource, clock: @escaping Clock) throws {
        guard (1...1024).contains(maximumEvents) else {
            throw QwenPrefillPhaseError("Phase capacity must be between one and 1024 events")
        }
        self.identity = identity; self.maximumEvents = maximumEvents
        self.clock = clock; self.clockSource = clockSource
        events.reserveCapacity(maximumEvents)
    }

    func begin(expectedIdentity: QwenPrefillPhaseIdentity) throws {
        lock.lock(); defer { lock.unlock() }
        guard state == .fresh, !readingClock, identity == expectedIdentity else {
            try reject("Phase recorder is not fresh or belongs to another request/profile/role")
        }
        state = .active
    }

    func observe(phase: String, frameSequence: Int? = nil, committedTokens: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard state == .active, !readingClock, events.count < maximumEvents,
              (1...96).contains(phase.utf8.count),
              phase.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 46 || $0 == 95 }),
              frameSequence == nil || (0..<128).contains(frameSequence!),
              (0...32768).contains(committedTokens),
              committedTokens >= (events.last?.committedTokens ?? 0) else {
            try reject("Invalid phase event, owner state, capacity or committed frontier")
        }
        readingClock = true
        defer { readingClock = false }
        do {
            let now = try clock()
            // An injected callback may have caught a reentrant error or called
            // fail(). Never publish an event after it invalidated the owner.
            guard state == .active, readingClock,
                  events.last == nil || now >= events.last!.localUptimeNanoseconds else {
                try reject("Phase clock moved backwards or recorder failed during its callback")
            }
            events.append(.init(ordinal: events.count, phase: phase, frameSequence: frameSequence,
                committedTokens: committedTokens, localUptimeNanoseconds: now))
        } catch {
            failLocked()
            throw error
        }
    }

    /// No clock read. No events become observable before successful sealing.
    func seal() throws {
        lock.lock(); defer { lock.unlock() }
        guard state == .active, !readingClock, let first = events.first, let last = events.last else {
            try reject("Only an active, nonempty phase recorder can be sealed once")
        }
        result = .init(identity: identity, clockSource: clockSource, maximumEvents: maximumEvents,
            events: events, firstLocalUptimeNanoseconds: first.localUptimeNanoseconds,
            lastLocalUptimeNanoseconds: last.localUptimeNanoseconds,
            traceSpanNanoseconds: last.localUptimeNanoseconds - first.localUptimeNanoseconds)
        events.removeAll(keepingCapacity: false)
        state = .sealed
    }

    /// Idempotent, nonthrowing and CPU-only; it cannot interrupt native work.
    func fail() {
        lock.lock(); defer { lock.unlock() }
        failLocked()
    }

    func successfulTrace() throws -> QwenPrefillPhaseTrace {
        lock.lock(); defer { lock.unlock() }
        guard state == .sealed, !readingClock, let result else {
            try reject("Phase trace is unavailable before successful seal or after failure")
        }
        return result
    }

    private func failLocked() {
        state = .failed
        events.removeAll(keepingCapacity: false)
        result = nil
    }

    private func reject(_ message: String) throws -> Never {
        failLocked()
        throw QwenPrefillPhaseError(message)
    }
}
