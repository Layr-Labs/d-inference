import Foundation
import Testing

@testable import ProviderCore

@Suite("Qwen4 reclaim-aware load admission", .serialized)
struct Qwen4ReclaimAdmissionTests {
    private enum FixtureError: Error { case unexpectedEngineBuild }

    private func makeLoop() throws -> ProviderLoop {
        try ProviderLoop(config: .init(
            coordinatorURL: "ws://127.0.0.1:0/unused",
            hardware: .init(machineModel: "memory-test", chipName: "Apple M5 Max",
                chipFamily: .m5, chipTier: .max, memoryGb: 128, memoryAvailableGb: 110,
                cpuCores: .init(total: 18, performance: 12, efficiency: 6),
                gpuCores: 40, memoryBandwidthGbs: 500),
            models: [.init(id: "qwen-reclaim-test", modelType: "qwen4_exp",
                           sizeBytes: 1 << 30, estimatedMemoryGb: 1)],
            config: .init(provider: .init(name: "reclaim-admission-test"),
                          backend: .init(idleTimeoutMins: 0, maxModelSlots: 1))),
            purgeLegacyFiles: false, attestationSigner: nil)
    }

    @Test func genuineShortageStillRefusesAfterWindowExpires() async throws {
        let loop = try makeLoop()
        await loop.setQwenReclaimFixture(available: 0, retiredAt: .now.advanced(by: .milliseconds(-1950)))
        await #expect(throws: InferenceError.self) {
            try await loop.evictUntilAvailable(weightsGb: 1, allowEviction: false,
                                              waitForQwen4Retirement: true)
        }
        #expect(await loop.outstandingKVReservationBytesForTesting() == 0)
    }

    @Test func recheckRequiresActualHeadroomRecovery() async throws {
        let loop = try makeLoop()
        await loop.setQwenReclaimFixture(available: 0, retiredAt: .now)
        let admission = Task {
            try await loop.evictUntilAvailable(weightsGb: 1, allowEviction: false,
                                              waitForQwen4Retirement: true)
        }
        try await Task.sleep(for: .milliseconds(40))
        await loop.setQwenReclaimFixture(available: 20, retiredAt: nil)
        try await admission.value
        #expect(await loop.outstandingKVReservationBytesForTesting() == 0,
                "A recheck is advisory, not an allocation permit")
    }

    @Test func nonQwenLoadCannotUseReclaimWindow() async throws {
        let loop = try makeLoop()
        await loop.setQwenReclaimFixture(available: 0, retiredAt: .now)
        await #expect(throws: InferenceError.self) {
            try await loop.evictUntilAvailable(weightsGb: 1, allowEviction: false)
        }
    }

    @Test func cancellationInterruptsRealProviderWait() async throws {
        let loop = try makeLoop()
        await loop.setQwenReclaimFixture(available: 0, retiredAt: .now)
        let admission = Task {
            try await loop.evictUntilAvailable(weightsGb: 1, allowEviction: false,
                                              waitForQwen4Retirement: true)
        }
        try await Task.sleep(for: .milliseconds(10))
        admission.cancel()
        await #expect(throws: CancellationError.self) { try await admission.value }
    }

    @Test func fastRejectStillHonorsFailedModelRetirement() async throws {
        let loop = try makeLoop()
        await loop.setQwenReclaimFixture(available: 0, retiredAt: .now)
        #expect(await !loop.fastAdmissionReject(modelId: "qwen-reclaim-test"))
        await loop.markRetiringForTesting("qwen-reclaim-test")
        #expect(await loop.fastAdmissionReject(modelId: "qwen-reclaim-test"))
    }
}

private extension ProviderLoop {
    func setQwenReclaimFixture(available: Double, retiredAt: ContinuousClock.Instant?) {
        engineV2SlotHooks = .init(availableMemoryGb: available, makeEngine: { _, _ in
            throw NSError(domain: "unexpected-reclaim-fixture-engine", code: 1)
        })
        qwen4MemoryRetirement = retiredAt.map { NativeMemoryRetirementWindow(retiredAt: $0) }
    }
}
