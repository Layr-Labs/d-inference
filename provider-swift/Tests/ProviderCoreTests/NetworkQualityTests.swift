import Testing
@testable import ProviderCore

@Test func providerStateStoresNetworkQuality() {
    let state = ProviderState()
    let quality = NetworkQuality(
        rttMs: 80,
        jitterMs: 12,
        reconnectCount: 2,
        websocketWriteFailures: 1,
        lastWriteLatencyMs: 4
    )

    state.networkQuality = quality

    #expect(state.networkQuality == quality)
}

@Test func networkQualityTrackerComputesPingRttAndJitterAndCounters() {
    let tracker = NetworkQualityTracker()

    tracker.recordPong(rttMs: 100)
    tracker.recordPong(rttMs: 140)
    tracker.recordReconnect()
    tracker.recordWriteFailure()
    tracker.recordWriteLatency(ms: 8)

    let snapshot = tracker.snapshot()
    #expect(snapshot.rttMs == 140)
    #expect(snapshot.jitterMs == 40)
    #expect(snapshot.reconnectCount == 1)
    #expect(snapshot.websocketWriteFailures == 1)
    #expect(snapshot.lastWriteLatencyMs == 8)
}
