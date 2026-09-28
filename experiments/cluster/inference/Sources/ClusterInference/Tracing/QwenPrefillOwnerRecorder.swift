import Foundation
import Dispatch

/// Optional caller-owned collector for exactly one selected chunk. No clock is
/// read during construction, sealing, failure or retrieval. The caller installs
/// the observer only for its admitted frame and fails it on every outer error.
final class QwenPrefillOwnerRecorder {
    typealias Clock = () throws -> UInt64
    private enum State: Equatable { case fresh, active, sealed, failed }
    private static let phases: [CBv2OwnerPhase] = [
        .graphConstructionBegin, .graphConstructionEnd,
        .rootStagingBegin, .rootStagingEnd,
        .evaluationBegin, .evaluationEnd,
        .validationCommitBegin, .validationCommitEnd,
    ]

    let identity: QwenPrefillOwnerIdentity
    private let clock: Clock
    private let clockSource: QwenPrefillOwnerClockSource
    private let lock = NSRecursiveLock()
    private var state = State.fresh
    private var readingClock = false
    private var events: [QwenPrefillOwnerEvent] = []
    private var result: QwenPrefillOwnerTrace?

    convenience init(identity: QwenPrefillOwnerIdentity) {
        self.init(identity: identity, clockSource: .dispatchUptimeNanoseconds,
            clock: { DispatchTime.now().uptimeNanoseconds })
    }

    /// Explicit test-only initializer; its traces never claim production clock.
    convenience init(testIdentity: QwenPrefillOwnerIdentity, clock: @escaping Clock) {
        self.init(identity: testIdentity, clockSource: .injectedTestClock, clock: clock)
    }

    private init(identity: QwenPrefillOwnerIdentity, clockSource: QwenPrefillOwnerClockSource,
                 clock: @escaping Clock) {
        self.identity = identity
        self.clockSource = clockSource
        self.clock = clock
        events.reserveCapacity(8)
    }

    /// Only the first correctly ordered observation activates a fresh recorder.
    /// Invalid metadata is rejected before reading the clock. Callback failures
    /// and caught reentrant misuse poison all later observations/publication.
    func observe(_ observation: CBv2OwnerPhaseObservation) throws {
        lock.lock(); defer { lock.unlock() }
        guard (state == .fresh || state == .active), !readingClock,
              events.count < Self.phases.count,
              observation.phase == Self.phases[events.count],
              observation.tokenCount == identity.tokenCount,
              observation.committedTokens == (events.count == 7
                ? identity.committedFrontier : identity.tokenOffset) else {
            try reject("Owner event violates phase order, exact selected frontier or lifecycle")
        }
        state = .active
        readingClock = true
        defer { readingClock = false }
        do {
            let now = try clock()
            guard state == .active, readingClock,
                  events.last == nil || now >= events.last!.localUptimeNanoseconds else {
                try reject("Owner clock reversed or recorder failed during clock callback")
            }
            events.append(.init(ordinal: events.count, phase: observation.phase.rawValue,
                tokenCount: observation.tokenCount, committedTokens: observation.committedTokens,
                localUptimeNanoseconds: now))
        } catch {
            failLocked()
            throw error
        }
    }

    /// Invoke once, only after the complete enclosing request/model owner and
    /// its final native error checks succeeded. This method cannot verify that
    /// external fact itself. It reads no clock and creates only CPU evidence.
    func sealAfterOuterSuccess() throws {
        lock.lock(); defer { lock.unlock() }
        guard state == .active, !readingClock, events.count == 8,
              let first = events.first, let last = events.last else {
            try reject("Owner trace needs exactly eight completed events and outer success")
        }
        result = .init(identity: identity, clockSource: clockSource, events: events,
            firstLocalUptimeNanoseconds: first.localUptimeNanoseconds,
            lastLocalUptimeNanoseconds: last.localUptimeNanoseconds,
            traceSpanNanoseconds: last.localUptimeNanoseconds - first.localUptimeNanoseconds)
        events.removeAll(keepingCapacity: false)
        state = .sealed
    }

    /// Idempotent CPU-only poisoning. It cannot interrupt a native operation.
    func fail() {
        lock.lock(); defer { lock.unlock() }
        failLocked()
    }

    func successfulTrace() throws -> QwenPrefillOwnerTrace {
        lock.lock(); defer { lock.unlock() }
        guard state == .sealed, !readingClock, let result else {
            try reject("Owner trace is unavailable before successful seal or after failure")
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
        throw QwenPrefillOwnerError(message)
    }
}
