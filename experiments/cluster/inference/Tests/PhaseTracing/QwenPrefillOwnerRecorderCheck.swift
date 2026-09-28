import Foundation

struct QwenPrefillOwnerRecorderCheckResult: Encodable {
    let kind = "qwen_prefill_owner_recorder_check"
    let acceptedTraces: Int
    let rejectedCalls: Int
    let nativeExecution = false
    let productionClockRead = false
}

private enum QwenPrefillOwnerFixtureError: Error { case assertion, clock }

/// Synthetic Foundation-only tests. No native work, files or production clocks.
func checkQwenPrefillOwnerRecorder() throws -> QwenPrefillOwnerRecorderCheckResult {
    var accepted = 0, rejected = 0
    func require(_ okay: Bool) throws {
        if !okay { throw QwenPrefillOwnerFixtureError.assertion }
    }
    func rejects(_ operation: () throws -> Void) throws {
        var failed = false
        do { try operation() } catch { failed = true }
        try require(failed); rejected += 1
    }
    func identity(_ role: QwenPrefillOwnerRole = .solo) throws -> QwenPrefillOwnerIdentity {
        try .init(requestFingerprint: String(repeating: "a", count: 64), profile: "long_prefill_8k_v1", role: role)
    }
    let phases: [CBv2OwnerPhase] = [.graphConstructionBegin, .graphConstructionEnd,
        .rootStagingBegin, .rootStagingEnd, .evaluationBegin, .evaluationEnd,
        .validationCommitBegin, .validationCommitEnd]
    func observation(_ index: Int) -> CBv2OwnerPhaseObservation {
        .init(phase: phases[index], tokenCount: 512, committedTokens: index == 7 ? 4096 : 3584)
    }
    func recorder(_ role: QwenPrefillOwnerRole = .solo, times: [UInt64]? = nil) throws -> QwenPrefillOwnerRecorder {
        let values = times ?? Array(1...8).map { UInt64($0) * 10 }
        var index = 0
        return .init(testIdentity: try identity(role), clock: {
            guard values.indices.contains(index) else { throw QwenPrefillOwnerFixtureError.clock }
            defer { index += 1 }; return values[index]
        })
    }
    func complete(_ recorder: QwenPrefillOwnerRecorder, count: Int = 8) throws {
        for index in 0..<count { try recorder.observe(observation(index)) }
    }
    let cases: [(QwenPrefillOwnerRole, [UInt64])] = [
        (.solo, [10,20,30,40,50,60,70,80]), (.rank0, [10,20,30,40,50,60,70,80]),
        (.rank1, [10,20,30,40,50,60,70,80]), (.solo, Array(repeating: 0, count: 8)),
        (.rank1, Array(repeating: UInt64.max, count: 8)),
        (.rank0, (0..<8).map { UInt64.max - 7 + UInt64($0) }),
    ]
    for (role, times) in cases {
        let r = try recorder(role, times: times); try complete(r); try r.sealAfterOuterSuccess()
        let trace = try r.successfulTrace()
        try require(trace.identity == identity(role) && trace.events.count == 8)
        try require(trace.clockSource == .injectedTestClock && trace.maximumEvents == 8)
        try require(trace.events.map(\.phase) == phases.map(\.rawValue))
        try require(trace.events.map(\.localUptimeNanoseconds) == times)
        try require(trace.firstLocalUptimeNanoseconds == times[0] && trace.lastLocalUptimeNanoseconds == times[7]
            && trace.traceSpanNanoseconds == times[7] - times[0])
        try require(try r.successfulTrace().events == trace.events)
        let encoded = try JSONEncoder().encode(trace)
        let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        let encodedIdentity = object["identity"] as! [String: Any]
        try require(Set(encodedIdentity.keys) == Set(["requestFingerprint","profile","role","frameSequence","tokenOffset","tokenCount","committedFrontier"]))
        try require((encodedIdentity["frameSequence"] as? Int) == 7 && (encodedIdentity["tokenOffset"] as? Int) == 3584
            && (encodedIdentity["tokenCount"] as? Int) == 512 && (encodedIdentity["committedFrontier"] as? Int) == 4096)
        try require(!trace.gpuKernelTimeAsserted && !trace.gpuOverlapAsserted && !trace.crossProcessClockAlignmentAsserted
            && !trace.modelReleaseAsserted && !trace.recorderIndependentlyVerifiesOuterSuccess)
        accepted += 1
    }
    for fp in ["", String(repeating: "a", count: 63), String(repeating: "a", count: 65),
               String(repeating: "A", count: 64), String(repeating: "g", count: 64),
               String(repeating: "a", count: 63) + "\n"] {
        try rejects { _ = try QwenPrefillOwnerIdentity(requestFingerprint: fp, profile: "long_prefill_8k_v1", role: .solo) }
    }
    for profile in ["", "legacy_bounded_v1", "LONG_PREFILL_8K_V1"] {
        try rejects { _ = try QwenPrefillOwnerIdentity(requestFingerprint: String(repeating: "a", count: 64), profile: profile, role: .solo) }
    }
    try require(QwenPrefillOwnerRole(rawValue: "rank2") == nil)
    for index in 0..<8 {
        let r = try recorder(); try complete(r, count: index)
        let wrong = CBv2OwnerPhaseObservation(phase: phases[(index + 1) % 8], tokenCount: 512,
            committedTokens: index == 7 ? 4096 : 3584)
        try rejects { try r.observe(wrong) }; try rejects { _ = try r.successfulTrace() }
        let r2 = try recorder(); try complete(r2, count: index)
        let wrongFrontier = CBv2OwnerPhaseObservation(phase: phases[index], tokenCount: 512,
            committedTokens: index == 7 ? 3584 : 4096)
        try rejects { try r2.observe(wrongFrontier) }; try rejects { try r2.observe(observation(index)) }
    }
    for width in [Int.min, -1, 0, 511, 513, Int.max] {
        var clockCalls = 0
        let r = QwenPrefillOwnerRecorder(testIdentity: try identity(), clock: { clockCalls += 1; return 0 })
        try rejects { try r.observe(.init(phase: .graphConstructionBegin, tokenCount: width, committedTokens: 3584)) }
        try require(clockCalls == 0)
    }
    for count in 0..<8 {
        let r = try recorder(); try complete(r, count: count)
        try rejects { try r.sealAfterOuterSuccess() }; try rejects { _ = try r.successfulTrace() }
    }
    do {
        let r = try recorder(); try complete(r)
        try rejects { try r.observe(observation(0)) }; try rejects { try r.sealAfterOuterSuccess() }
    }
    do {
        let r = try recorder(); try complete(r); try r.sealAfterOuterSuccess()
        try rejects { try r.sealAfterOuterSuccess() }; try rejects { _ = try r.successfulTrace() }
    }
    do {
        let r = try recorder(); try complete(r); try r.sealAfterOuterSuccess()
        try rejects { try r.observe(observation(0)) }; try rejects { _ = try r.successfulTrace() }
    }
    do {
        let r = try recorder(); try complete(r)
        try rejects { _ = try r.successfulTrace() }; try rejects { try r.sealAfterOuterSuccess() }
    }
    for count in [0,3,8] {
        let r = try recorder(); try complete(r, count: count); r.fail(); r.fail()
        try rejects { try r.observe(observation(0)) }; try rejects { try r.sealAfterOuterSuccess() }
    }
    do {
        let r = try recorder(); try complete(r); try r.sealAfterOuterSuccess(); r.fail()
        try rejects { _ = try r.successfulTrace() }
    }
    do {
        let r = try recorder(times: [10,20,30,29,50,60,70,80]); try complete(r, count: 3)
        try rejects { try r.observe(observation(3)) }; try rejects { try r.sealAfterOuterSuccess() }
    }
    do {
        let r = QwenPrefillOwnerRecorder(testIdentity: try identity(), clock: { throw QwenPrefillOwnerFixtureError.clock })
        var originalError = false
        do { try r.observe(observation(0)) } catch QwenPrefillOwnerFixtureError.clock { originalError = true }
        try require(originalError); try rejects { try r.sealAfterOuterSuccess() }
    }
    for action in 0..<4 {
        weak var active: QwenPrefillOwnerRecorder?
        let r = QwenPrefillOwnerRecorder(testIdentity: try identity(), clock: {
            guard let active else { throw QwenPrefillOwnerFixtureError.assertion }
            switch action {
            case 0: try? active.observe(observation(0))
            case 1: try? active.sealAfterOuterSuccess()
            case 2: _ = try? active.successfulTrace()
            default: active.fail()
            }
            return 42
        })
        active = r
        try rejects { try r.observe(observation(0)) }; try rejects { try r.sealAfterOuterSuccess() }
    }
    // No production observe call: this only checks the disabled/caller-owned shape.
    let unused = QwenPrefillOwnerRecorder(identity: try identity()); unused.fail()
    try rejects { _ = try unused.successfulTrace() }
    return .init(acceptedTraces: accepted, rejectedCalls: rejected)
}
