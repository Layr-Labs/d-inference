import Foundation
import Testing

@testable import ProviderCore

@Suite("Shared service changes refresh capacity without polling")
struct WholeMacServiceHeartbeatTests {
    @Test func preSubmitAndRetirementFromDifferentModelsRefreshPublishedInput() async throws {
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30)
        }
        let config = ProviderLoopConfig(coordinatorURL: "ws://127.0.0.1:0/unused",
            hardware: HardwareInfo(machineModel: "Mac16,5", chipName: "Apple M4 Max",
                chipFamily: .m4, chipTier: .max, memoryGb: 64, memoryAvailableGb: 64,
                cpuCores: .init(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546),
            models: [], config: ProviderConfig(provider: .init(name: "service-heartbeat"),
                backend: .init(), coordinator: .init(heartbeatIntervalSecs: 60)))
        let loop = try ProviderLoop(config: config, attestationSigner: nil, kvBudgetForTesting: budget)
        // Deliberately never start the periodic capacity task. All observed
        // rebuilds must come from the shared allowance change stream.
        await loop.startServiceAllowanceRefreshMonitor()
        do {
            try await expectUsage(0, on: loop)
            #expect(budget.serviceBudget.acquire(ownerID: "local-model-a:pre-submit", concurrency: 16))
            try await expectUsage(1.0 / 16.0, on: loop)
            #expect(budget.serviceBudget.acquire(ownerID: "remote-model-b:retiring", concurrency: 24))
            try await expectUsage(1.0 / 16.0 + 1.0 / 24.0, on: loop)
            budget.serviceBudget.release(ownerID: "local-model-a:pre-submit")
            try await expectUsage(1.0 / 24.0, on: loop)
            budget.serviceBudget.release(ownerID: "remote-model-b:retiring")
            try await expectUsage(0, on: loop)
            await loop.stopServiceAllowanceRefreshMonitor()
            #expect(budget.serviceBudget.acquire(ownerID: "after-stop", concurrency: 16))
            #expect(await loop.backendCapacityForTesting()?.wholeMacServiceUsed == 0)
            // Restart consumes ownership acquired while detached, and the old
            // stream's cancellation cannot unregister its replacement.
            await loop.startServiceAllowanceRefreshMonitor()
            try await expectUsage(1.0 / 16.0, on: loop)
            budget.serviceBudget.release(ownerID: "after-stop")
            try await expectUsage(0, on: loop)
            await loop.stopServiceAllowanceRefreshMonitor()
        } catch {
            await loop.stopServiceAllowanceRefreshMonitor()
            throw error
        }
    }

    private func expectUsage(_ expected: Double, on loop: ProviderLoop) async throws {
        let until = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < until {
            if let capacity = await loop.backendCapacityForTesting(),
                let used = capacity.wholeMacServiceUsed, abs(used - expected) < 1e-12 {
                #expect(capacity.slots.isEmpty, "No slot/count change may account for this rebuild")
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("service allowance change did not refresh capacity: expected \(expected)")
    }
}
