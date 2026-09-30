import Testing
@testable import ProviderCore

@Test("queued slot work keeps daemon load diagnosis temporary")
func daemonWorkPostureSeesQueuedSlotWithoutActiveDecode() {
    let waiting = BackendSlotCapacity(
        model: "qwen", state: "idle", numRunning: 0, numWaiting: 1,
        activeTokens: 0, maxTokensPotential: 1000)
    let capacity = BackendCapacity(
        slots: [waiting], gpuMemoryActiveGb: 0, gpuMemoryPeakGb: 0,
        gpuMemoryCacheGb: 0, totalMemoryGb: 48)
    #expect(DaemonWorkPosture.hasPendingRequest(inflight: false, capacity: capacity))
    #expect(DaemonWorkPosture.hasPendingRequest(inflight: true, capacity: nil))
    #expect(!DaemonWorkPosture.hasPendingRequest(inflight: false, capacity: nil))
}
