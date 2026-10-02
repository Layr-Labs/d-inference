import Foundation

/// The native factory requires the concrete admitted phase-resource owner.
/// Ordinary generation wrappers remain nil. The separate CPU fixture factory
/// cannot create resident authority or native clock evidence.
final class QwenGenerationPhaseRecorder {
    #if QWEN_GENERATION_PHASE_FIXTURE
    static let nativeObservationEntryAvailable = false
    #else
    static let nativeObservationEntryAvailable = true
    #endif
    private enum State: Equatable { case fresh, active, sealed, failed }
    private let identity: QwenGenerationPhaseIdentity
    private let budget: QwenGenerationPhaseBudget
    private let clock: () throws -> UInt64
    private let clockSource: String
    private let reservationCheck: () throws -> Void
    private let lock = NSRecursiveLock()
    private var state = State.fresh
    private var readingClock = false
    private var checkingReservation = false
    private var events: [QwenGenerationPhaseEvent] = []
    private var localFrontier = 0
    private var agreedFrontier = 0
    private var trace: QwenGenerationPhaseTrace?

    private init(identity: QwenGenerationPhaseIdentity, budget: QwenGenerationPhaseBudget,
                 clock: @escaping () throws -> UInt64,
                 clockSource: String = "injected_cpu_fixture",
                 reservationCheck: @escaping () throws -> Void) throws {
        try identity.validate(); try reservationCheck()
        self.identity = identity; self.budget = budget
        self.clock = clock; self.clockSource = clockSource; self.reservationCheck = reservationCheck
        events.reserveCapacity(budget.maximumEvents)
        let actual = events.capacity.multipliedReportingOverflow(by: MemoryLayout<QwenGenerationPhaseEvent>.stride)
        guard !actual.overflow, actual.partialValue <= budget.eventAllocationBytes else {
            throw QwenGenerationPhaseError("Actual event capacity exceeds its reserved host buffer")
        }
        try reservationCheck()
    }

    #if QWEN_GENERATION_PHASE_FIXTURE
    /// Fabricated CPU authority only. This flag is absent from native products.
    static func forCPUFixture(identity: QwenGenerationPhaseIdentity,
        budget: QwenGenerationPhaseBudget, clock: @escaping () throws -> UInt64,
        reservationCheck: @escaping () throws -> Void) throws -> QwenGenerationPhaseRecorder {
        try .init(identity: identity, budget: budget, clock: clock, reservationCheck: reservationCheck)
    }
    #endif

    #if !QWEN_GENERATION_PHASE_FIXTURE
    static func forResident(_ resources: QwenResidentPhaseResources) throws -> QwenGenerationPhaseRecorder {
        try resources.requireLive(force: true)
        return try .init(identity: resources.identity, budget: resources.budget,
            clock: { DispatchTime.now().uptimeNanoseconds }, clockSource: "dispatch_uptime_nanoseconds",
            reservationCheck: { try resources.requireLive() })
    }
    #endif

    func begin(expected: QwenGenerationPhaseIdentity) throws {
        lock.lock(); defer { lock.unlock() }
        guard state == .fresh, !readingClock, !checkingReservation, identity == expected else { try reject("Observation identity or state differs") }
        do { try checkReservation(); state = .active }
        catch { failLocked(); throw error }
    }

    func observe(_ value: QwenGenerationPhaseObservation) throws {
        lock.lock(); defer { lock.unlock() }
        do {
            guard state == .active, !readingClock, !checkingReservation, events.count < budget.maximumEvents,
                  value.phase.requiredRank == nil || value.phase.requiredRank == identity.rank else {
                try reject("Observation is inactive, reentrant, over capacity or wrong-rank")
            }
            if let frame = value.frame {
                let count = (identity.promptCount - 1) / identity.chunkSize + 1
                guard (0..<count).contains(frame.sequence),
                      frame.tokenOffset == frame.sequence * identity.chunkSize,
                      frame.tokenCount == min(identity.chunkSize, identity.promptCount - frame.tokenOffset),
                      frame.finalPromptChunk == (frame.sequence == count - 1) else {
                    try reject("Observation frame differs from the admitted prompt")
                }
            }
            func frontier(_ value: Int?, previous: Int) throws -> Int {
                guard let value else { return previous }
                guard value >= previous, value <= identity.promptCount + identity.outputCount else {
                    throw QwenGenerationPhaseError("Observation frontier reversed or exceeded its request")
                }
                return value
            }
            let nextLocal = try frontier(value.localCommittedTokens, previous: localFrontier)
            let nextAgreed = try frontier(value.agreedCommittedTokens, previous: agreedFrontier)
            try checkReservation()
            readingClock = true
            defer { readingClock = false }
            let now = try clock()
            guard state == .active, readingClock,
                  events.last == nil || now >= events.last!.localUptimeNanoseconds else {
                try reject("Observation clock reversed or invalidated its owner")
            }
            events.append(.init(ordinal: events.count, observation: value, localUptimeNanoseconds: now))
            localFrontier = nextLocal; agreedFrontier = nextAgreed
        } catch { failLocked(); throw error }
    }

    /// Marker presence is not independent retirement proof. The native owner
    /// calls this only after the shared core's successful retirement epilogue.
    func seal() throws {
        lock.lock(); defer { lock.unlock() }
        do {
            guard state == .active, !readingClock, !checkingReservation, let first = events.first, let last = events.last,
                  first.observation.phase == .requestBegin, last.observation.phase == .requestRetired else {
                try reject("Incomplete observation cannot be sealed")
            }
            try checkReservation()
            trace = .init(identity: identity, clockSource: clockSource,
                maximumEvents: budget.maximumEvents, requiredHostReservationBytes: budget.requiredHostReservationBytes,
                events: events, firstLocalUptimeNanoseconds: first.localUptimeNanoseconds,
                lastLocalUptimeNanoseconds: last.localUptimeNanoseconds)
            events = []; state = .sealed
        } catch { failLocked(); throw error }
    }

    func successfulTrace() throws -> QwenGenerationPhaseTrace {
        lock.lock(); defer { lock.unlock() }
        guard state == .sealed, !readingClock, !checkingReservation, let trace else { try reject("Observation has no successful trace") }
        do { try checkReservation(); return trace }
        catch { failLocked(); throw error }
    }

    func fail() { lock.lock(); defer { lock.unlock() }; failLocked() }
    private func checkReservation() throws {
        guard !checkingReservation else { try reject("Reentrant observation reservation check") }
        checkingReservation = true
        defer { checkingReservation = false }
        try reservationCheck()
        guard state != .failed else { throw QwenGenerationPhaseError("Observation failed during its reservation check") }
    }
    private func failLocked() { state = .failed; events = []; trace = nil }
    private func reject(_ message: String) throws -> Never {
        failLocked(); throw QwenGenerationPhaseError(message)
    }
}
