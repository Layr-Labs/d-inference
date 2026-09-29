import Foundation
import Testing
@testable import ProviderCore

private final class DeadlineTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: ContinuousClock.Instant
    init(_ now: ContinuousClock.Instant = .now) { instant = now }
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    func advance(_ duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }
}

private let cooledRequirement = DeadlineApplicability(minimumWholeMacQuiescenceMs: 20_000,
    minimumNominalStabilityMs: 5_000, powerMode: "automatic")

func deadlineReadyServiceBudgetFixture() -> WholeMacServiceBudget {
    let posture = DeadlinePostureState()
    let now = ContinuousClock.now
    for halfSecond in 0...10 {
        let sample = now.advanced(by: .milliseconds((halfSecond - 10) * 500))
        posture.observe(nominal: true, lowPower: false, automatic: true, source: "ac",
            powerReadAt: sample, at: sample)
    }
    return WholeMacServiceBudget(posture: posture)
}

private func sample(_ posture: DeadlinePostureState, _ clock: DeadlineTestClock,
    nominal: Bool = true, automatic: Bool = true, lowPower: Bool = false, source: String? = "ac") {
    posture.observe(nominal: nominal, lowPower: lowPower, automatic: automatic,
        source: source, powerReadAt: clock.now, at: clock.now)
}

private func elapse(_ milliseconds: Int, posture: DeadlinePostureState, clock: DeadlineTestClock) {
    for _ in 0..<(milliseconds / 500) { clock.advance(.milliseconds(500)); sample(posture, clock) }
}

@Test func deadlineCooledApplicabilityCapturesHistoryBeforeOnlyIncomingLease() throws {
    let clock = DeadlineTestClock(), posture = DeadlinePostureState()
    let budget = WholeMacServiceBudget(clockNow: { clock.now }, posture: posture)
    sample(posture, clock)
    elapse(19_500, posture: posture, clock: clock)
    #expect(!budget.deadlineEligibleForAdvertisement(cooledRequirement))
    elapse(500, posture: posture, clock: clock)
    #expect(budget.deadlineEligibleForAdvertisement(cooledRequirement))
    #expect(budget.acquire(ownerID: "incoming", concurrency: 24,
        work: .init(modelID: "model", profileID: "reviewed", promptTokens: 8_828, maxOutputTokens: 128),
        deadlineApplicability: cooledRequirement))
    #expect(!budget.deadlineEligibleForAdvertisement(cooledRequirement))
    let first = try #require(budget.calibrationSnapshot(ownerID: "incoming", modelID: "model",
        profileID: "reviewed", applicability: cooledRequirement))
    #expect(first.evidenceGuard.isValid && first.postureValidUntil != nil)
    // Even a brief later owner invalidates this attempt permanently; removing
    // it cannot reconstruct an incoming request's pre-acquire cooling history.
    #expect(budget.acquire(ownerID: "another", concurrency: 24))
    budget.release(ownerID: "another")
    #expect(!first.evidenceGuard.isValid)
    #expect(budget.calibrationSnapshot(ownerID: "incoming", modelID: "model",
        profileID: "reviewed", applicability: cooledRequirement) == nil)
    budget.release(ownerID: "incoming")
    elapse(19_500, posture: posture, clock: clock)
    #expect(!budget.deadlineEligibleForAdvertisement(cooledRequirement))
    elapse(500, posture: posture, clock: clock)
    #expect(budget.deadlineEligibleForAdvertisement(cooledRequirement))
}

@Test func deadlineCooledApplicabilityStartsAfterLastUnboundedActivityRetires() {
    let clock = DeadlineTestClock(), posture = DeadlinePostureState()
    let budget = WholeMacServiceBudget(clockNow: { clock.now }, posture: posture)
    sample(posture, clock)
    let first = budget.beginUnboundedActivity(), second = budget.beginUnboundedActivity()
    elapse(20_000, posture: posture, clock: clock)
    first.finish()
    #expect(!budget.deadlineEligibleForAdvertisement(cooledRequirement))
    second.finish()
    elapse(19_500, posture: posture, clock: clock)
    #expect(!budget.deadlineEligibleForAdvertisement(cooledRequirement))
    elapse(500, posture: posture, clock: clock)
    #expect(budget.deadlineEligibleForAdvertisement(cooledRequirement))
}

@Test func deadlinePostureChangesInvalidateCapturedAtomicProofAndDoNotReviveIt() throws {
    let clock = DeadlineTestClock(), posture = DeadlinePostureState()
    let budget = WholeMacServiceBudget(clockNow: { clock.now }, posture: posture)
    sample(posture, clock)
    elapse(20_000, posture: posture, clock: clock)
    #expect(budget.acquire(ownerID: "incoming", concurrency: 24,
        work: .init(modelID: "model", profileID: "reviewed", promptTokens: 4_096, maxOutputTokens: 128),
        deadlineApplicability: cooledRequirement))
    let proof = try #require(budget.calibrationSnapshot(ownerID: "incoming", modelID: "model",
        profileID: "reviewed", applicability: cooledRequirement))
    sample(posture, clock, automatic: false) // High Power also refuses this Automatic-only record.
    #expect(!proof.evidenceGuard.isValid)
    sample(posture, clock)
    elapse(5_000, posture: posture, clock: clock)
    #expect(budget.calibrationSnapshot(ownerID: "incoming", modelID: "model",
        profileID: "reviewed", applicability: cooledRequirement) == nil)
    budget.release(ownerID: "incoming")
}

@Test func deadlinePostureRequiresFreshContinuousNominalAutomaticEvidence() throws {
    let clock = DeadlineTestClock(), posture = DeadlinePostureState()
    sample(posture, clock)
    elapse(5_000, posture: posture, clock: clock)
    let original = try #require(posture.snapshot(requirement: cooledRequirement, at: clock.now))
    #expect(posture.snapshot(requirement: cooledRequirement, at: clock.now.advanced(by: .seconds(1))) == nil)
    clock.advance(.seconds(2))
    sample(posture, clock)
    #expect(posture.snapshot(requirement: cooledRequirement, at: clock.now) == nil)
    elapse(5_000, posture: posture, clock: clock)
    #expect(posture.snapshot(requirement: cooledRequirement, at: clock.now)?.epoch != original.epoch)
    for failure in ["thermal", "low", "high", "unknown", "source"] {
        sample(posture, clock, nominal: failure != "thermal", automatic: failure != "high",
            lowPower: failure == "low", source: failure == "unknown" ? nil : failure == "source" ? "battery" : "ac")
        #expect(posture.snapshot(requirement: cooledRequirement, at: clock.now) == nil)
        sample(posture, clock)
        elapse(5_000, posture: posture, clock: clock)
    }
    posture.observe(nominal: true, lowPower: false, automatic: true, source: "ac",
        powerReadAt: clock.now.advanced(by: .seconds(-3)), at: clock.now)
    #expect(posture.snapshot(requirement: cooledRequirement, at: clock.now) == nil)
}

@Test func deadlineBatteryAutomaticCannotBorrowFreshACRatesAfterCooling() throws {
    let clock = DeadlineTestClock(), posture = DeadlinePostureState()
    let budget = WholeMacServiceBudget(clockNow: { clock.now }, posture: posture)
    sample(posture, clock)
    elapse(20_000, posture: posture, clock: clock)
    #expect(budget.deadlineEligibleForAdvertisement(cooledRequirement))
    let work = WholeMacServiceBudget.Work(modelID: "model", profileID: "reviewed",
        promptTokens: 8_828, maxOutputTokens: 128)
    #expect(budget.acquire(ownerID: "ac", concurrency: 24, work: work,
        deadlineApplicability: cooledRequirement))
    let acProof = try #require(budget.calibrationSnapshot(ownerID: "ac", modelID: "model",
        profileID: "reviewed", applicability: cooledRequirement))
    var rates = EnginePerformanceMeasurements()
    for (phase, tps) in [("isolated_prefill", 900.0), ("decode", 80.0)] {
        rates.observe(phase, tps: tps, prompt: 8_828, context: 8_828,
            cache: "cold", overlap: .init(), at: clock.now)
    }
    sample(posture, clock, source: "battery")
    #expect(!acProof.evidenceGuard.isValid)
    budget.release(ownerID: "ac")
    for _ in 0..<60 {
        clock.advance(.milliseconds(500))
        sample(posture, clock, source: "battery")
    }
    // Both old AC rates are still fresh, and the Mac has been idle/nominal on
    // Battery Automatic beyond both windows. None of that qualifies battery.
    #expect(rates.freshRate("isolated_prefill", now: clock.now) != nil)
    #expect(rates.freshRate("decode", now: clock.now) != nil)
    #expect(!budget.deadlineEligibleForAdvertisement(cooledRequirement))
    #expect(budget.acquire(ownerID: "battery", concurrency: 24, work: work,
        deadlineApplicability: cooledRequirement))
    #expect(budget.calibrationSnapshot(ownerID: "battery", modelID: "model",
        profileID: "reviewed", applicability: cooledRequirement) == nil)
    budget.release(ownerID: "battery")
    sample(posture, clock)
    elapse(20_000, posture: posture, clock: clock)
    #expect(budget.deadlineEligibleForAdvertisement(cooledRequirement))
    #expect(!acProof.evidenceGuard.isValid)
}

@Test func deadlinePowerPolicyParserDistinguishesAutomaticHighLowAndUnknown() {
    #expect(DeadlinePowerPolicyReader.parseModes("AC Power:\n powermode 0\nBattery Power:\n powermode 2\n") == ["ac": 0, "battery": 2])
    #expect(DeadlinePowerPolicyReader.parseModes("Battery Power:\n powermode 1\n") == ["battery": 1])
    #expect(DeadlinePowerPolicyReader.parseModes("AC Power:\n lowpowermode 0\n") == nil)
    #expect(DeadlinePowerPolicyReader.parseModes("AC Power:\n powermode 9\n") == nil)
    #expect(DeadlinePowerPolicyReader.parseModes("AC Power:\n powermode 0\n powermode 2\n") == nil)
}

private final class DeadlineSampleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

@Test func deadlinePostureMonitoringStopsAfterLastProfileOwnerWithoutPowerProcesses() async throws {
    let samples = DeadlineSampleCounter()
    let monitor = DeadlinePostureMonitor(readModes: { ["ac": 0] },
        activeSource: { samples.increment(); return "ac" }, readThermal: { (true, false) })
    let first = monitor.acquire(), second = monitor.acquire()
    try await Task.sleep(for: .milliseconds(600))
    #expect(samples.count > 0)
    first.finish()
    let whileOwned = samples.count
    try await Task.sleep(for: .milliseconds(600))
    #expect(samples.count > whileOwned)
    second.finish()
    // Let an already executing callback return; cancelled generations cannot
    // publish new eligible history or continue sampling without an owner.
    try await Task.sleep(for: .milliseconds(100))
    let stopped = samples.count
    try await Task.sleep(for: .milliseconds(600))
    #expect(samples.count == stopped)
    #expect(monitor.state.snapshot(requirement: cooledRequirement, at: .now) == nil)
}

@Test func deadlineProfileRequiresExplicitMeasuredApplicabilityFields() throws {
    let profile = deadlineCalibrationProfileFixture()
    var raw = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
    for key in ["minimum_whole_mac_quiescence_ms", "minimum_nominal_stability_ms", "power_mode"] {
        var missing = raw
        missing.removeValue(forKey: key)
        let data = try JSONSerialization.data(withJSONObject: missing)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(DeadlinePerformanceProfile.self, from: data) }
    }
    raw["minimum_whole_mac_quiescence_ms"] = 0
    let explicit = try JSONDecoder().decode(DeadlinePerformanceProfile.self,
        from: JSONSerialization.data(withJSONObject: raw))
    #expect(explicit.isValid)
}
