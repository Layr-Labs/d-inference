import Foundation

struct QwenPrefillPhaseRecorderCheckResult: Encodable {
    let kind = "qwen_prefill_phase_recorder_check"
    let cpuOnly = true, injectedTestClocksOnly = true
    let acceptedFixtures: Int, rejectedFixtures: Int
    let nativeModelUsed = false, nativeTransportUsed = false
}

/// Pure Foundation fixtures. Root compiles/runs this separately from inference.
func checkQwenPrefillPhaseRecorder() throws -> QwenPrefillPhaseRecorderCheckResult {
    let identity = try QwenPrefillPhaseIdentity(requestFingerprint: String(repeating: "a", count: 64),
        profile: "long_prefill_8k_v1", role: .rank0)
    var accepted = 0, rejected = 0
    func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw QwenPrefillPhaseError(message) }
    }
    func reject(_ label: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { rejected += 1; return }
        throw QwenPrefillPhaseError("Invalid fixture was accepted: " + label)
    }
    func recorder(_ capacity: Int = 512) throws -> QwenPrefillPhaseRecorder {
        try .init(identity: identity, maximumEvents: capacity, testClock: { 100 })
    }
    func active(_ capacity: Int = 512) throws -> QwenPrefillPhaseRecorder {
        let result = try recorder(capacity); try result.begin(expectedIdentity: identity); return result
    }

    // init, begin, seal and successfulTrace do not read the clock themselves.
    var reads = 0
    let first = try QwenPrefillPhaseRecorder(identity: identity, maximumEvents: 3,
        testClock: { reads += 1; return UInt64(reads * 7) })
    try require(reads == 0, "Initialization read a clock")
    try first.begin(expectedIdentity: identity)
    try require(reads == 0, "Begin read a clock")
    try first.observe(phase: "prepare.begin", frameSequence: 0, committedTokens: 0)
    try first.observe(phase: "prepare.committed", frameSequence: 0, committedTokens: 512)
    try first.seal()
    let trace = try first.successfulTrace()
    try require(reads == 2 && trace.clockSource == .injectedTestClock && trace.events.count == 2
        && trace.events.map(\.ordinal) == [0, 1] && trace.traceSpanNanoseconds == 7,
        "Actual injected timestamps or sealed event order differ")
    _ = try first.successfulTrace()
    try require(reads == 2, "Reading a sealed result consulted the clock")
    accepted += 1

    let tied = try active(2)
    try tied.observe(phase: "one", committedTokens: 0); try tied.observe(phase: "two", committedTokens: 0)
    try tied.seal(); try require(tied.successfulTrace().traceSpanNanoseconds == 0, "Equal timestamps were rejected")
    accepted += 1

    let maximum = try QwenPrefillPhaseRecorder(identity: identity, testClock: { UInt64.max })
    try maximum.begin(expectedIdentity: identity); try maximum.observe(phase: "one", committedTokens: 0)
    try maximum.seal(); try require(maximum.successfulTrace().traceSpanNanoseconds == 0, "UInt64 maximum overflowed")
    accepted += 1

    // Optional chaining skips argument construction as well as recorder calls.
    let absent: QwenPrefillPhaseRecorder? = nil
    var arguments = 0
    func countedIdentity() -> QwenPrefillPhaseIdentity { arguments += 1; return identity }
    func countedPhase() -> String { arguments += 1; return "unused" }
    try absent?.begin(expectedIdentity: countedIdentity())
    try absent?.observe(phase: countedPhase(), committedTokens: 0)
    try absent?.seal(); absent?.fail()
    if let _ = try absent?.successfulTrace() { throw QwenPrefillPhaseError("Nil recorder produced a trace") }
    try require(arguments == 0, "Nil observer evaluated metadata arguments")
    accepted += 1

    // The largest current owner trace fits; this fixture is metadata-only.
    let bounded = try active(235)
    for index in 0..<235 { try bounded.observe(phase: "owner.event", committedTokens: min(index * 32, 8192)) }
    try bounded.seal(); try require(bounded.successfulTrace().events.count == 235, "Bounded trace lost events")
    accepted += 1

    let invalidIDs = ["", String(repeating: "a", count: 63), String(repeating: "A", count: 64)]
    for pin in invalidIDs {
        try reject("request fingerprint") { _ = try QwenPrefillPhaseIdentity(requestFingerprint: pin, profile: identity.profile, role: .rank0) }
    }
    for profile in ["", "long-prefill", String(repeating: "a", count: 65)] {
        try reject("profile spelling") { _ = try QwenPrefillPhaseIdentity(requestFingerprint: identity.requestFingerprint, profile: profile, role: .rank0) }
    }
    for capacity in [0, 1025, Int.max] { try reject("capacity") { _ = try recorder(capacity) } }

    for other in [try QwenPrefillPhaseIdentity(requestFingerprint: String(repeating: "b", count: 64), profile: identity.profile, role: .rank0),
                  try QwenPrefillPhaseIdentity(requestFingerprint: identity.requestFingerprint, profile: "another_profile", role: .rank0),
                  try QwenPrefillPhaseIdentity(requestFingerprint: identity.requestFingerprint, profile: identity.profile, role: .rank1)] {
        let r = try recorder()
        try reject("wrong owner") { try r.begin(expectedIdentity: other) }
        try reject("poisoned owner cannot restart") { try r.begin(expectedIdentity: identity) }
    }
    let beforeBegin = try recorder()
    try reject("observe before begin") { try beforeBegin.observe(phase: "before", committedTokens: 0) }
    try reject("early observation poisoned owner") { try beforeBegin.begin(expectedIdentity: identity) }
    let duplicateBegin = try active()
    try reject("second begin") { try duplicateBegin.begin(expectedIdentity: identity) }
    let empty = try active()
    try reject("empty seal") { try empty.seal() }
    let earlyRead = try active()
    try reject("partial trace visibility") { _ = try earlyRead.successfulTrace() }
    try reject("early read poisoned owner") { try earlyRead.observe(phase: "late", committedTokens: 0) }
    try reject("repeat seal") { try first.seal() }
    try reject("repeat seal invalidates retrieval") { _ = try first.successfulTrace() }
    let over = try active(1); try over.observe(phase: "one", committedTokens: 0)
    try reject("capacity exceeded") { try over.observe(phase: "two", committedTokens: 0) }
    try reject("capacity failure cannot seal") { try over.seal() }

    for phase in ["", "bad phase", "bad/phase", String(repeating: "x", count: 97)] {
        let r = try active(); try reject("phase name") { try r.observe(phase: phase, committedTokens: 0) }
    }
    for frame in [-1, 128, Int.max] {
        let r = try active(); try reject("frame bound") { try r.observe(phase: "event", frameSequence: frame, committedTokens: 0) }
    }
    for frontier in [-1, 32769, Int.max] {
        let r = try active(); try reject("token bound") { try r.observe(phase: "event", committedTokens: frontier) }
    }
    let backwardsFrontier = try active(); try backwardsFrontier.observe(phase: "first", committedTokens: 512)
    try reject("decreasing frontier") { try backwardsFrontier.observe(phase: "second", committedTokens: 0) }

    var ticks: [UInt64] = [10, 9]
    let backwardsClock = try QwenPrefillPhaseRecorder(identity: identity, testClock: { ticks.removeFirst() })
    try backwardsClock.begin(expectedIdentity: identity); try backwardsClock.observe(phase: "first", committedTokens: 0)
    try reject("decreasing time") { try backwardsClock.observe(phase: "second", committedTokens: 0) }
    try reject("clock reversal cannot seal") { try backwardsClock.seal() }

    enum ClockFailure: Error { case injected }
    let throwing = try QwenPrefillPhaseRecorder(identity: identity, testClock: { throw ClockFailure.injected })
    try throwing.begin(expectedIdentity: identity)
    do {
        try throwing.observe(phase: "throws", committedTokens: 0)
        throw QwenPrefillPhaseError("Throwing clock was accepted")
    } catch ClockFailure.injected { accepted += 1 }
    try reject("clock failure cannot seal") { try throwing.seal() }

    // A callback which catches an invalid reentrant call still poisons the outer
    // observation; it cannot smuggle a success after violating the lifecycle.
    for action in 0..<3 {
        var r: QwenPrefillPhaseRecorder?
        defer { r = nil }
        r = try QwenPrefillPhaseRecorder(identity: identity, testClock: {
            if action == 0 { try? r?.observe(phase: "nested", committedTokens: 0) }
            else if action == 1 { try? r?.seal() }
            else { r?.fail() }
            return 1
        })
        try r!.begin(expectedIdentity: identity)
        try reject("reentrant invalidation") { try r!.observe(phase: "outer", committedTokens: 0) }
        try reject("reentrant invalidation cannot publish") { _ = try r!.successfulTrace() }
    }
    let failed = try active(); try failed.observe(phase: "before_failure", committedTokens: 0)
    failed.fail(); failed.fail()
    try reject("explicit failure hides partial trace") { _ = try failed.successfulTrace() }
    tied.fail()
    try reject("outer failure invalidates sealed trace") { _ = try tied.successfulTrace() }
    return .init(acceptedFixtures: accepted, rejectedFixtures: rejected)
}
