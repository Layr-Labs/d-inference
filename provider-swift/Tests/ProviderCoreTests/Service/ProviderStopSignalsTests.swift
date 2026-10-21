import Darwin
import Testing
@testable import ProviderCore

@Suite("Provider stop signals")
struct ProviderStopSignalsTests {
    @Test("SIGHUP is a stop signal only for a start by hand that did not arrive ignoring it")
    func hangupStopsOnlyAStartByHand() {
        #expect(ProviderStopSignals.resolve(launchedByLaunchd: false, hangupIgnoredAtStart: false)
            == [SIGTERM, SIGINT, SIGHUP])
        #expect(ProviderStopSignals.resolve(launchedByLaunchd: true, hangupIgnoredAtStart: false)
            == [SIGTERM, SIGINT])
        #expect(ProviderStopSignals.resolve(launchedByLaunchd: false, hangupIgnoredAtStart: true)
            == [SIGTERM, SIGINT])
        #expect(ProviderStopSignals.resolve(launchedByLaunchd: true, hangupIgnoredAtStart: true)
            == [SIGTERM, SIGINT])
    }
}
