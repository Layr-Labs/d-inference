import Foundation
import MLX
import MLXLMCommon
@testable import ProviderCore

/// Owns every stream until its terminal and every loaded slot until shutdown.
actor ReleaseCoResidencyHarness {
    let fixture: ReleaseCoResidencyFixture
    let fixtureSHA256: String
    let hardware: HardwareInfo
    let loop: ProviderLoop
    private var bridges: [String: EngineV2Bridge] = [:]
    private var collectors: [String: Task<ReleaseCoResidencyStreamResult, Never>] = [:]
    private var probes: [String: ReleaseCoResidencyStreamProbe] = [:]
    private var cacheStartStats: [String: SSDHybridCheckpointStats] = [:]
    private var observations: [ReleaseCoResidencyObservation] = []
    private var results: [String: ReleaseCoResidencyStreamResult] = [:]
    private var shrinkObserved: Set<String> = []

    init(fixture: ReleaseCoResidencyFixture, fixtureSHA256: String, hardware: HardwareInfo,
         runtimeCapabilities: Set<ProviderRuntimeCapability>) throws {
        self.fixture = fixture; self.fixtureSHA256 = fixtureSHA256; self.hardware = hardware
        loop = try ProviderLoop(config: ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/ignored", hardware: hardware, models: try fixture.modelInfos(),
            config: ProviderConfig(
                provider: ProviderSettings(name: "release090-coresidency", memoryReserveGB: fixture.memoryReserveGiB),
                backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 3,
                    engineV2MaxConcurrent: 1, engineV2KVBackend: "paged", mtpMode: .auto),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)),
            runtimeCapabilities: runtimeCapabilities),
            purgeLegacyFiles: false, attestationSigner: nil)
    }

    func run() async throws {
        await loop.setEngineV2RuntimeForTesting(EngineV2Runtime())
        let first = fixture.models[0].modelID
        try await load(first)
        try await capture("one-slot")
        try await recover(fixture.models[0], suffix: "alone")
        for index in 1...2 {
            let requestID = "release090-load-\(index)"
            try await start(fixture.streaming, id: requestID)
            try await waitForOutput(id: requestID)
            try await loadDuringStream(fixture.models[index].modelID, requestID: requestID)
            try await cancelAndDrain(id: requestID)
            for model in fixture.models.prefix(index + 1) {
                try await recover(model, suffix: "slots-\(index + 1)")
            }
            try await capture("drained-\(index + 1)-slots")
        }
        let grantThree = await bridges[first]!.engineKVBytesCapacity()
        await loop.unloadModel(fixture.models[2].modelID)
        bridges.removeValue(forKey: fixture.models[2].modelID)
        try await capture("unload-third-regrow")
        let grantTwo = await bridges[first]!.engineKVBytesCapacity()
        try ReleaseCoResidencyFixture.require(grantTwo > grantThree, "survivor did not regrow after third-slot unload")
        await loop.unloadModel(fixture.models[1].modelID)
        bridges.removeValue(forKey: fixture.models[1].modelID)
        try await capture("unload-second-regrow")
        try ReleaseCoResidencyFixture.require(await bridges[first]!.engineKVBytesCapacity() > grantTwo,
                                              "survivor did not regrow after second-slot unload")
        try await recover(fixture.models[0], suffix: "regrown")
        try await capture("recovery-after-regrow")
    }

    private func load(_ modelID: String) async throws {
        try await loop.ensureModelLoaded(modelId: modelID)
        guard let bridge = await loop.slotBridgeForTesting(modelId: modelID) else {
            throw ReleaseCoResidencyFailure("newcomer has no live bridge")
        }
        bridges[modelID] = bridge
    }

    private func start(_ prompt: ReleaseCoResidencyFixture.Prompt, id: String) async throws {
        guard let bridge = bridges[prompt.request.model], collectors[id] == nil else {
            throw ReleaseCoResidencyFailure("missing bridge or duplicate request")
        }
        if id.hasPrefix("release090-load-") {
            guard let store = bridge.ssdHybridCheckpointStore else { throw ReleaseCoResidencyFailure("Qwen SSD store missing") }
            cacheStartStats[id] = store.stats()
            try await capture("before-restored-stream-\(id)")
        }
        let stream = await bridge.submitTokenized(promptTokens: prompt.tokens, request: prompt.request,
            requestId: id, cacheScope: "release090-coresidency", cacheEnabled: true)
        let probe = ReleaseCoResidencyStreamProbe()
        probes[id] = probe
        collectors[id] = Task { await probe.consume(stream) }
    }

    private func waitForOutput(id: String) async throws {
        let deadline = ContinuousClock.now + .seconds(180)
        while ContinuousClock.now < deadline {
            if let probe = probes[id], await probe.hasOutput() {
                try await requireActive(id)
                guard let before = cacheStartStats[id],
                      let after = bridges[fixture.models[0].modelID]?.ssdHybridCheckpointStore?.stats() else {
                    throw ReleaseCoResidencyFailure("restore counters missing")
                }
                try ReleaseCoResidencyFixture.require(after.stageConsumptions > before.stageConsumptions
                    && after.consumedPrefixTokens > before.consumedPrefixTokens
                    && after.stageReadBytes > before.stageReadBytes,
                    "stream did not consume an authenticated SSD prefix")
                // Restore completes before newcomer loading; this does not
                // claim that SSD I/O overlaps the later model load.
                try await capture("restored-before-load-\(id)")
                return
            }
            if let probe = probes[id], await probe.completed() {
                throw ReleaseCoResidencyFailure("stream ended before overlap could begin")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ReleaseCoResidencyFailure("stream never produced output before load")
    }

    private func requireActive(_ id: String) async throws {
        guard let bridge = bridges[fixture.models[0].modelID] else { throw ReleaseCoResidencyFailure("stream bridge missing") }
        let capacity = await bridge.capacitySnapshot()
        try ReleaseCoResidencyFixture.require(await bridge._testActiveRequestIds().contains(id)
            && capacity.activeRequests > 0, "stream was not actually active during newcomer load")
    }

    private func observeShrink(id: String, oldGrant: Int) async throws {
        try await requireActive(id)
        let grant = await bridges[fixture.models[0].modelID]!.engineKVBytesCapacity()
        if grant < oldGrant && !shrinkObserved.contains(id) {
            shrinkObserved.insert(id)
            try await capture("shrink-observed-active-\(id)")
        }
    }

    private func loadDuringStream(_ newcomer: String, requestID: String) async throws {
        let oldGrant = await bridges[fixture.models[0].modelID]!.engineKVBytesCapacity()
        try await requireActive(requestID)
        try await capture("load-begin-\(newcomer)")
        // The load and observer are structured children. A failure/cancellation
        // awaits both before the outer cleanup can unload any model.
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { [loop] in
                try await loop.ensureModelLoaded(modelId: newcomer)
                return true
            }
            group.addTask {
                let deadline = ContinuousClock.now + .seconds(300)
                while ContinuousClock.now < deadline {
                    try Task.checkCancellation()
                    try await self.observeShrink(id: requestID, oldGrant: oldGrant)
                    try await Task.sleep(for: .milliseconds(50))
                }
                throw ReleaseCoResidencyFailure("newcomer load exceeded overlap deadline")
            }
            let loaded = try await group.next()
            group.cancelAll()
            try ReleaseCoResidencyFixture.require(loaded == true, "newcomer did not finish loading")
        }
        guard let bridge = await loop.slotBridgeForTesting(modelId: newcomer) else {
            throw ReleaseCoResidencyFailure("newcomer bridge absent after completed load")
        }
        bridges[newcomer] = bridge
        try await observeShrink(id: requestID, oldGrant: oldGrant)
        try ReleaseCoResidencyFixture.require(shrinkObserved.contains(requestID), "no real grant shrink while streaming")
        try await capture("load-end-active-\(newcomer)")
    }

    private func cancelAndDrain(id: String) async throws {
        try await requireActive(id)
        let bridge = bridges[fixture.models[0].modelID]!
        await bridge.cancel(requestId: id)
        let result = await collectors[id]!.value
        results[id] = result
        collectors.removeValue(forKey: id); probes.removeValue(forKey: id)
        try ReleaseCoResidencyFixture.require(result.errors == ["request cancelled"] && result.completionTokens > 0,
                                              "cancellation did not settle an active generating request")
        try await drain(bridge)
    }

    private func recover(_ model: ReleaseCoResidencyFixture.Model, suffix: String) async throws {
        let id = "release090-recovery-\(model.modelID)-\(suffix)"
        try await start(model.recovery, id: id)
        let result = await collectors[id]!.value
        results[id] = result
        collectors.removeValue(forKey: id); probes.removeValue(forKey: id)
        try ReleaseCoResidencyFixture.require(result.errors.isEmpty && result.completionTokens > 0
            && result.completionTokens <= model.recovery.request.max_tokens! && result.finishReason != nil,
            "recovery request did not complete normally")
        try await drain(bridges[model.modelID]!)
    }

    private func drain(_ bridge: EngineV2Bridge) async throws {
        await bridge.ssdHybridCheckpointStore?.waitForWritesForTesting()
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            let c = await bridge.capacitySnapshot()
            let stats = bridge.ssdHybridCheckpointStore?.stats()
            if await bridge._testActiveRequestIds().isEmpty && c.activeRequests == 0 && c.waitingRequests == 0
                && c.kvBytesInUse == 0 && c.kvBytesReserved == 0
                && c.pagedStorage?.livePageBytes == 0 && c.pagedStorage?.reservedPageBytes == 0
                && (stats?.stagedBytesInUse ?? 0) == 0 && (stats?.writeHostBytesInUse ?? 0) == 0 { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ReleaseCoResidencyFailure("request/native/SSD reservations did not drain")
    }

    private func capture(_ stage: String) async throws {
        observations.append(try await ReleaseCoResidencyObservation.capture(stage: stage, loop: loop,
            bridges: bridges, reserveGiB: fixture.memoryReserveGiB))
        try report(failure: nil, complete: false, cleanupComplete: false)
    }

    /// Called and awaited by the test on success AND error. No deferred Task.
    func cleanup() async -> Bool {
        for bridge in bridges.values {
            for id in await bridge._testActiveRequestIds() { await bridge.cancel(requestId: id) }
        }
        // Include a newcomer which failed after installation but before our
        // dictionary was updated. ProviderLoop owns those slots as well.
        for model in fixture.models.reversed() { await loop.unloadModel(model.modelID) }
        var slotsRetired = true
        for model in fixture.models {
            if await loop.slotSizingForTesting(modelId: model.modelID) != nil { slotsRetired = false }
        }
        for (id, task) in collectors { results[id] = await task.value }
        collectors.removeAll(); probes.removeAll(); bridges.removeAll(); cacheStartStats.removeAll()
        MLX.Memory.clearCache()
        let budget = await loop.kvBudgetForTesting()
        let sample = budget.memoryHeadroomSnapshot()
        let clean = slotsRetired && sample.ownerCount == 0 && sample.closingOwnerCount == 0
            && sample.totalOwnedBytes == 0 && sample.unmaterializedCommittedBytes == 0
            && sample.materializedBytes == 0 && sample.commitmentDebtBytes == 0
        if let snapshot = try? await ReleaseCoResidencyObservation.capture(stage: "all-unloaded", loop: loop,
            bridges: [:], reserveGiB: fixture.memoryReserveGiB) { observations.append(snapshot) }
        return clean
    }

    func report(failure: String?, complete: Bool, cleanupComplete: Bool) throws {
        struct Report: Encodable {
            let fixtureSHA256: String; let hardware: HardwareInfo
            let observations: [ReleaseCoResidencyObservation]
            let requests: [String: ReleaseCoResidencyStreamResult]
            let shrinkObserved: [String]
            let complete: Bool; let cleanupComplete: Bool; let failure: String?
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Report(fixtureSHA256: fixtureSHA256, hardware: hardware,
            observations: observations, requests: results, shrinkObserved: shrinkObserved.sorted(),
            complete: complete, cleanupComplete: cleanupComplete, failure: failure))
        try data.write(to: URL(fileURLWithPath: fixture.outputPath), options: .atomic)
    }
}
