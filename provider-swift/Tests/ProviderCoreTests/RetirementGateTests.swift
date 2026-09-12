import Testing
@testable import ProviderCore

/// A model mid-retirement (failed its load self-test; drain and coordinator
/// un-advertisement in flight) must not accept NEW inference through the
/// resident-slot fast paths: `fastAdmissionReject` must reject fast (the
/// coordinator reroutes) and `ensureModelLoaded` must throw rather than
/// serve a build that failed its serving-path self-test.
@Suite("Retirement inference gate")
struct RetirementGateTests {
    private func makeLoop() throws -> ProviderLoop {
        let config = ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/ignored",
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4,
                chipTier: .max,
                memoryGb: 128, memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546
            ),
            models: [],
            config: ProviderConfig(
                provider: ProviderSettings(name: "retirement-gate-test", memoryReserveGB: 1),
                backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 2),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
            )
        )
        return try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)
    }

    @Test func retiringModelIsRejectedByBothFastPaths() async throws {
        let loop = try makeLoop()
        // Control: an unknown, non-retiring id is NOT fast-rejected (the
        // post-accept path owns the proper 404).
        #expect(await loop.fastAdmissionReject(modelId: "some-model") == false)

        await loop.markRetiringForTesting("some-model")
        // Fast admission rejects immediately → the coordinator reroutes.
        #expect(await loop.fastAdmissionReject(modelId: "some-model") == true)
        // The load path throws the retiring error (503-mapped via the
        // "slot" wording) instead of proceeding to any fast path.
        do {
            try await loop.ensureModelLoaded(modelId: "some-model")
            Issue.record("ensureModelLoaded unexpectedly succeeded for a retiring model")
        } catch let InferenceError.invalidModelDirectory(message) {
            #expect(message.contains("retiring"))
            #expect(
                ProviderLoop.loadErrorStatusCode(
                    for: InferenceError.invalidModelDirectory(message)) == 503)
        }
    }
}
