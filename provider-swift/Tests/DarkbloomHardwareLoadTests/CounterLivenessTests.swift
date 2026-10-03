import Testing

@testable import DarkbloomHardwareLoad

struct CounterLivenessTests {
    @Test func valuesStayNullUntilTheCounterMoves() {
        var liveness = CounterLiveness(available: [.gpuPower])
        #expect(liveness.gate(.gpuPower, CounterReading(value: 0, moved: false)) == nil)
        #expect(liveness.status(.gpuPower) == .pending)
        #expect(liveness.gate(.gpuPower, CounterReading(value: 42, moved: true)) == 42)
        #expect(liveness.status(.gpuPower) == .measured)
    }

    @Test func aLiveCounterReportsTrueZero() {
        var liveness = CounterLiveness(available: [.aneBandwidth])
        _ = liveness.gate(.aneBandwidth, CounterReading(value: 3.5, moved: true))
        #expect(liveness.gate(.aneBandwidth, CounterReading(value: 0, moved: false)) == 0)
        #expect(liveness.status(.aneBandwidth) == .estimated)
    }

    @Test func missingReadingsAndUnsubscribedCountersAreNull() {
        var liveness = CounterLiveness(available: [.gpuPower])
        _ = liveness.gate(.gpuPower, CounterReading(value: 1, moved: true))
        #expect(liveness.gate(.gpuPower, nil) == nil)
        #expect(liveness.gate(.anePower, CounterReading(value: 5, moved: true)) == nil)
        #expect(liveness.status(.anePower) == .unavailable)
    }
}
