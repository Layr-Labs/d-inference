import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

private struct PerformanceHeartbeatFixture {
    let loop: ProviderLoop
    let runtime: EngineV2Runtime
    let engine: PrefillScriptEngine
    let bridge: EngineV2Bridge
    let hardware: HardwareInfo

    static func make() async throws -> Self {
        let hardware = HardwareInfo(machineModel: "Mac16,5", chipName: "Apple M4 Max",
            chipFamily: .m4, chipTier: .max, memoryGb: 64, memoryAvailableGb: 64,
            cpuCores: .init(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546)
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30)
        }
        let loop = try ProviderLoop(config: .init(coordinatorURL: "ws://127.0.0.1:0/unused",
            hardware: hardware, models: [], config: .init(provider: .init(name: "performance-heartbeat"),
                backend: .init(), coordinator: .init(heartbeatIntervalSecs: 60))),
            attestationSigner: nil, kvBudgetForTesting: budget)
        let engine = PrefillScriptEngine()
        let tokenizer = CancelledPrefixTokenizer(prompt: Array(repeating: 7, count: 200))
        let bridge = EngineV2Bridge(engine: engine, modelId: "fixture-model",
            tokenizer: TokenizerHandle(tokenizer), eosTokenIds: [])
        let runtime = EngineV2Runtime()
        await runtime.register(modelId: "fixture-model", bridge: bridge)
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.installModelSlotForTesting(modelId: "fixture-model",
            container: cancelledPrefixContainer(tokenizer: tokenizer),
            tokenizer: TokenizerHandle(tokenizer), engineV2: bridge)
        return Self(loop: loop, runtime: runtime, engine: engine, bridge: bridge, hardware: hardware)
    }

    func submit(_ id: String) async -> Task<Void, Never> {
        let stream = await bridge.submitTokenized(promptTokens: Array(repeating: 7, count: 200),
            request: .init(model: "fixture-model", messages: [.init(role: "user", content: "fixture")]), requestId: id)
        return Task { for await _ in stream {} }
    }

    func close() async {
        await loop.stopPerformanceRefreshMonitor()
        await loop.stopPerformanceTestTimer()
        await bridge.shutdown()
        _ = await runtime.unregister(modelId: "fixture-model")
    }

    func waitForPrefills(_ count: Int64) async throws -> BackendCapacity {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if let capacity = await loop.backendCapacityForTesting(),
                capacity.slots.first?.telemetry?.prefillRequestsTotal == count { return capacity }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw NSError(domain: "PerformanceHeartbeat", code: 1)
    }
}

private extension ProviderLoop {
    func stopPerformanceTestTimer() {
        trailingHeartbeatTask?.cancel()
        trailingHeartbeatTask = nil
    }
}

@Suite("Early performance capacity publication")
struct EnginePerformanceHeartbeatTests {
    enum Prompt: CaseIterable, Equatable, Sendable { case cold, vision, reused, tooFast }

    @Test(arguments: Prompt.allCases)
    func promptCompletionRebuildsBeforeOutputWithoutPolling(_ kind: Prompt) async throws {
        let f = try await PerformanceHeartbeatFixture.make()
        let consumer = await f.submit("held-generation")
        // Neither the periodic capacity task nor the service-budget observer
        // runs. The script keeps all slot counts and token budgets unchanged.
        await f.loop.startPerformanceRefreshMonitor()
        do {
            let before = try await f.waitForPrefills(0)
            var usage = CBv2Usage(promptTokens: 200, completionTokens: 0,
                prefixCacheOutcome: kind == .reused ? .hit : .miss,
                prefixCachePrefillTokensSaved: kind == .reused ? 100 : 0)
            var timing = CBv2RequestTiming()
            timing.prefillFirstLaunchNanos = 1_000_000
            timing.promptComputedNanos = kind == .tooFast ? 1_000_001 : 101_000_000
            timing.visionChunks = kind == .vision ? 1 : 0
            usage.timing = timing
            f.engine.completePrefill(usage)
            let early = try await f.waitForPrefills(1)
            let slot = try #require(early.slots.first)
            #expect(slot.telemetry?.prefillTokensTotal == (kind == .reused ? 100 : 200))
            #expect(slot.telemetry?.generationRequestsTotal == 0)
            #expect(slot.performanceMeasurements?.isolatedPrefill?.sampleCount == (kind == .cold ? 1 : nil))
            #expect(slot.numRunning == before.slots.first?.numRunning)
            #expect(slot.activeTokenBudgetUsed == before.slots.first?.activeTokenBudgetUsed)
            #expect(CapacityHeartbeatMateriality.isMaterial(previous: before, current: early))
            #expect(await f.bridge.activeRequestCount() == 1)
            // Callback replay cannot create new work or a second sample.
            f.engine.completePrefill(usage)
            let receipt = try #require(await f.bridge.active["held-generation"]?.prefillReceipt)
            await f.bridge.consumePrefillReceipt(id: "held-generation", receipt: receipt)
            #expect(await f.bridge.backendSlotCapacity().telemetry?.prefillRequestsTotal == 1)
            await f.close()
            await consumer.value
        } catch {
            await f.close()
            await consumer.value
            throw error
        }
    }

    @Test func stoppedMonitorCanResubscribeAndIncludesMissedMeasurements() async throws {
        let f = try await PerformanceHeartbeatFixture.make()
        let first = await f.submit("first")
        await f.loop.startPerformanceRefreshMonitor()
        do {
            _ = try await f.waitForPrefills(0)
            await f.loop.stopPerformanceRefreshMonitor()
            f.engine.completeColdPrefill()
            let receipt = try #require(await f.bridge.active["first"]?.prefillReceipt)
            await f.bridge.consumePrefillReceipt(id: "first", receipt: receipt)
            #expect(await f.loop.backendCapacityForTesting()?.slots.first?.telemetry?.prefillRequestsTotal == 0)
            await f.loop.startPerformanceRefreshMonitor()
            _ = try await f.waitForPrefills(1)
            let second = await f.submit("second")
            f.engine.completeColdPrefill(index: 1)
            _ = try await f.waitForPrefills(2)
            await f.close()
            await first.value
            await second.value
        } catch {
            await f.close()
            await first.value
            throw error
        }
    }

    @Test func replacedBridgeNotificationReadsOnlyTheCurrentRuntimeSlot() async throws {
        let f = try await PerformanceHeartbeatFixture.make()
        let oldConsumer = await f.submit("old-engine")
        await f.loop.startPerformanceRefreshMonitor()
        let replacementEngine = PrefillScriptEngine()
        let replacement = EngineV2Bridge(engine: replacementEngine, modelId: "fixture-model",
            tokenizer: TokenizerHandle(PrefillStubTokenizer()), eosTokenIds: [])
        do {
            let before = try await f.waitForPrefills(0)
            let epoch = await replacement.backendSlotCapacity().performanceMeasurements?.epoch
            #expect(epoch != before.slots.first?.performanceMeasurements?.epoch)
            // Normal load, revision activation and MTP replacement all install
            // their notification sink through this shared registration seam.
            await f.runtime.register(modelId: "fixture-model", bridge: replacement)
            f.engine.completeColdPrefill()
            let deadline = ContinuousClock.now + .seconds(3)
            while await f.loop.backendCapacityForTesting()?.slots.first?.performanceMeasurements?.epoch != epoch,
                ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            let current = try #require(await f.loop.backendCapacityForTesting()?.slots.first)
            #expect(current.performanceMeasurements?.epoch == epoch)
            #expect(current.telemetry?.prefillRequestsTotal == 0)
            let stream = await replacement.submitTokenized(promptTokens: Array(repeating: 7, count: 200),
                request: .init(model: "fixture-model", messages: [.init(role: "user", content: "fixture")]),
                requestId: "replacement-engine")
            let consumer = Task { for await _ in stream {} }
            replacementEngine.completeColdPrefill()
            let measured = try await f.waitForPrefills(1)
            #expect(measured.slots.first?.performanceMeasurements?.epoch == epoch)
            await replacement.shutdown()
            await consumer.value
            await f.close()
            await oldConsumer.value
        } catch {
            await replacement.shutdown()
            await f.close()
            await oldConsumer.value
            throw error
        }
    }
}

extension CoordinatorIntegrationTests {
    @Test("prefill completion reaches the wire while generation is held")
    func earlyPrefillEventHeartbeat() async throws {
        let mock = MockCoordinator()
        let url = try await mock.start()
        let f = try await PerformanceHeartbeatFixture.make()
        let consumer = await f.submit("wire-held")
        // Drain the subscription's startup rebuild before connecting. The
        // count-1 frame below must be driven by prompt completion itself.
        await f.loop.startPerformanceRefreshMonitor()
        _ = try await f.waitForPrefills(0)
        let client = CoordinatorClient(config: .init(url: url.mockProviderWebSocketURL(),
            hardware: f.hardware, models: [], backendName: "mlx-swift", heartbeatInterval: 60),
            stats: AtomicProviderStats(), state: await f.loop.state)
        await f.loop.setCoordinatorClientForTesting(client)
        _ = await client.start()
        do {
            try #require(try await mock.awaitFirstRegister(timeout: .seconds(5)) != nil)
            let deadline = ContinuousClock.now + .seconds(5)
            while !(await client.sessionRegistered), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            await client.sendEventHeartbeat()
            try #require(try await mock.waitForSnapshot(timeout: .seconds(3)) { !$0.heartbeats.isEmpty } != nil)
            f.engine.completeColdPrefill()
            let result = try await mock.waitForSnapshot(timeout: .seconds(3)) {
                $0.heartbeats.contains { $0.backendCapacity?.slots.first?.telemetry?.prefillRequestsTotal == 1 }
            }
            let heartbeat = try #require(result?.heartbeats.last)
            #expect(heartbeat.backendCapacity?.slots.first?.performanceMeasurements?.isolatedPrefill?.sampleCount == 1)
            #expect(heartbeat.backendCapacity?.slots.first?.telemetry?.generationRequestsTotal == 0)
            #expect(await f.bridge.activeRequestCount() == 1)
            await f.close()
            await consumer.value
            await client.shutdown()
            await mock.shutdown()
        } catch {
            await f.close()
            await consumer.value
            await client.shutdown()
            await mock.shutdown()
            throw error
        }
    }
}
