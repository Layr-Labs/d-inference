import Foundation
import Testing

@testable import InferenceWorkerCore

@Suite("KV pool sweep wiring")
struct KVPoolSweepWiringTests {
    @Test("worker maintenance starts and stops the periodic pool sweep")
    func workerMaintenanceSweepLifecycle() async {
        let server = StandaloneServer(config: StandaloneServerConfig(port: 0))
        #expect(await server.debugKVSweepSignalCount() == 0)
        await server.startMaintenance()
        let signalled = await pollUntil {
            await server.debugKVSweepSignalCount() > 0
        }
        #expect(signalled)
        await server.shutdown()
        try? await Task.sleep(for: .milliseconds(100))
        let stoppedAt = await server.debugKVSweepSignalCount()
        try? await Task.sleep(for: .milliseconds(1_200))
        #expect(await server.debugKVSweepSignalCount() == stoppedAt)
    }
}

private func pollUntil(
    timeout: Duration = .seconds(3),
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}
