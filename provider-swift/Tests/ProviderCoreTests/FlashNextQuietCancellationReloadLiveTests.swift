import Foundation
import MLXLLM
import MLXLMCommon
import Testing

@testable import ProviderCore

/// Opt-in, real-weight provider lifecycle test. No injected engine, artificial
/// pause, prefill-size override or forged profiler stamp is used. Only the
/// transport sink, software consumer key and tenant identity are synthetic.
/// This is handler cancellation/unload/reload evidence, not a WebSocket,
/// signed-persistence, cross-model switch or every-cancellation-phase test.
@Suite("Flash-Next quiet cancellation and real reload", .serialized)
struct FlashNextQuietCancellationReloadLiveTests {
    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["DARKBLOOM_FLASH_NEXT_QUIET_LIVE"] == "1"
            && ProcessInfo.processInfo.environment["DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST"] == "1",
        "Requires the explicit owned Flash-Next artifact and exclusive model lane"))
    func cancelsActualPrefillBeforeContentThenReleasesAndReloads() async throws {
        let env = ProcessInfo.processInfo.environment
        try #require(env["DARKBLOOM_PREFIX_CACHE"] == "0")
        try #require(env["DARKBLOOM_CBV2_MTP"] != "0", "This fixture requires active embedded MTP")
        let modelID = Qwen4SupportPolicy.ownedModelID
        let model = try verifiedOwnedModel(modelID: modelID, environment: env)
        let initialPLE = Qwen4ExpPLEResourceMetrics.snapshot()
        try #require(initialPLE == .init(mappedFiles: 0, activeRowBufferBytes: 0, cachedRowBufferBytes: 0),
                     "Fresh exclusive process must not already own PLE resources")
        let hardware = try HardwareDetector.detect()
        let loop = try ProviderLoop(config: .init(
            coordinatorURL: "ws://127.0.0.1:1/unused", hardware: hardware, models: [model],
            config: .init(provider: .init(name: "flash-next-quiet-reload-fixture"),
                          backend: .init(idleTimeoutMins: 0, maxModelSlots: 1, mtpMode: .auto))),
            purgeLegacyFiles: false, attestationSigner: nil)
        await loop.setEngineV2RuntimeForTesting(EngineV2Runtime())
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flash-next-quiet-reload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        await loop.setDaemonStateFileForTesting(root.appendingPathComponent("state.json"))
        let receiver = NodeKeyPair.generate()
        let recorder = FlashNextLifecycleRecorder(receiver: receiver)
        let requestPrefix = "flash-next-lifecycle-\(UUID().uuidString)"
        var requestIDs: [String] = []
        do {
            await loop.recordFlashNextLifecycleMemory("before_initial_load")
            try await loop.ensureModelLoaded(modelId: modelID, allowEviction: false)
            await loop.recordFlashNextLifecycleMemory("after_initial_load")
            let firstBridge = try #require(await loop.slotBridgeForTesting(modelId: modelID))
            let firstOwners = try await loop.flashNextLifecycleOwners(modelID)
            try #require(firstOwners.textTargetIsAlive, "Witness must track the actual inner text model")
            try #require(await firstBridge.kvBackendKind == .paged)
            try #require(await firstBridge.mtpStatusSnapshot().active)
            try #require(Qwen4ExpPLEResourceMetrics.snapshot().mappedFiles > 0)

            let baselineID = requestPrefix + "-baseline"
            requestIDs.append(baselineID)
            let baseline = try await generateReference(
                loop: loop, bridge: firstBridge, modelID: modelID, requestID: baselineID,
                receiver: receiver, recorder: recorder)
            let before = await firstBridge.capacitySnapshot()
            try #require(before.activeRequests == 0 && before.waitingRequests == 0)
            let quietID = requestPrefix + "-quiet"
            requestIDs.append(quietID)
            let profile = RequestProfileBuilder()
            let records = (0..<1024).map {
                "Record \($0): amber birch cobalt delta echo foxtrot golf hotel."
            }.joined(separator: "\n")
            try await submit(
                loop: loop, modelID: modelID, requestID: quietID, receiver: receiver,
                recorder: recorder, profile: profile,
                prompt: records + "\nIgnore the records. Count from 1 to 10000, separated by commas.",
                maxTokens: 2048)

            let observation = try await observeRealQuietPrefill(
                bridge: firstBridge, profile: profile, recorder: recorder,
                requestID: quietID, priorSteps: before.stepsExecuted)
            // The profiler derives .prefill from the actual engine-submit and
            // first-delta stamps when cancellation reaches the real handler.
            await loop.recordFlashNextLifecycleMemory("before_quiet_cancel")
            await loop.handleCancellation(requestId: quietID)
            try await waitForDrain(loop: loop, bridge: firstBridge, recorder: recorder,
                                   requestID: quietID, timeout: .seconds(15))
            await loop.recordFlashNextLifecycleMemory("after_quiet_cancel_drain")
            let cancelled = try recorder.output(for: quietID)
            let failure = try #require(cancelled.failures.first)
            #expect(cancelled.failures.count == 1 && cancelled.completions == 0)
            #expect(failure.code == .cancelled && failure.statusCode == 499)
            #expect(cancelled.content.isEmpty && cancelled.reasoning.isEmpty && !cancelled.sawTool)
            #expect(profile.wireObject().cancelStage == .prefill)
            #expect(profile.wireObject().firstDeltaUs == nil)
            print("Flash-Next quiet cancel: actual_steps=\(observation.stepsExecuted - before.stepsExecuted) "
                + "active_tokens=\(observation.activeTokens) live_pages=\(observation.pagedStorage?.livePageBytes ?? -1) "
                + "stage=\(profile.wireObject().cancelStage?.rawValue ?? "missing") output_chars=\(cancelled.content.count)")

            let readmitID = requestPrefix + "-readmit"
            requestIDs.append(readmitID)
            let readmit = try await generateReference(
                loop: loop, bridge: firstBridge, modelID: modelID, requestID: readmitID,
                receiver: receiver, recorder: recorder)
            #expect(readmit == baseline, "Readmission must match the pre-cancel output and usage")

            await loop.recordFlashNextLifecycleMemory("before_unload")
            try #require(await loop.unloadModel(modelID), "Real loaded slot must retire")
            try await requireReleased(loop: loop, bridge: firstBridge, owners: firstOwners, expectedPLE: initialPLE)

            await loop.recordFlashNextLifecycleMemory("after_unload_before_reload")
            try await loop.ensureModelLoaded(modelId: modelID, allowEviction: false)
            await loop.recordFlashNextLifecycleMemory("after_reload")
            let reloadedBridge = try #require(await loop.slotBridgeForTesting(modelId: modelID))
            let reloadedOwners = try await loop.flashNextLifecycleOwners(modelID)
            #expect(reloadedBridge !== firstBridge, "Reload must construct a fresh bridge")
            try #require(await reloadedBridge.kvBackendKind == .paged)
            try #require(await reloadedBridge.mtpStatusSnapshot().active)
            #expect(Qwen4ExpPLEResourceMetrics.snapshot().mappedFiles > 0)
            let reloadID = requestPrefix + "-reload"
            requestIDs.append(reloadID)
            let reloaded = try await generateReference(
                loop: loop, bridge: reloadedBridge, modelID: modelID, requestID: reloadID,
                receiver: receiver, recorder: recorder)
            #expect(reloaded == baseline, "Fresh reload must match the original output and usage")
            try #require(await loop.unloadModel(modelID))
            try await requireReleased(loop: loop, bridge: reloadedBridge, owners: reloadedOwners, expectedPLE: initialPLE)
            await loop.recordFlashNextLifecycleMemory("after_final_unload")
            print("Flash-Next reload: weak container/outer and inner target released; PLE gauges restored; baseline/readmit/reload equal")
        } catch {
            await loop.recordFlashNextLifecycleMemory("failure_before_cleanup")
            for requestID in requestIDs { await loop.handleCancellation(requestId: requestID) }
            _ = await loop.unloadModel(modelID)
            throw error
        }
    }

    private func submit(
        loop: ProviderLoop, modelID: String, requestID: String, receiver: NodeKeyPair,
        recorder: FlashNextLifecycleRecorder, profile: RequestProfileBuilder = .init(),
        prompt: String, maxTokens: Int
    ) async throws {
        let request = try JSONSerialization.data(withJSONObject: [
            "model": modelID, "messages": [["role": "user", "content": prompt]],
            "temperature": 0, "seed": 424242, "max_tokens": maxTokens,
            "enable_thinking": false, "reasoning": ["enabled": false],
            "stream": true, "stream_options": ["include_usage": true],
        ])
        let encrypted = try receiver.encrypt(
            recipientPublicKey: await loop.keyPair.publicKeyBytes, plaintext: request)
        await loop.handleInferenceRequest(
            requestId: requestID, ciphertext: encrypted, senderPublicKey: receiver.publicKeyBytes,
            cacheReceiptNonce: nil, authenticatedCacheScope: "synthetic-lifecycle-tenant",
            profile: profile, send: SendHandle(recorder.record))
    }

    private func generateReference(
        loop: ProviderLoop, bridge: EngineV2Bridge, modelID: String, requestID: String,
        receiver: NodeKeyPair, recorder: FlashNextLifecycleRecorder
    ) async throws -> FlashNextLifecycleIdentity {
        try await submit(loop: loop, modelID: modelID, requestID: requestID,
            receiver: receiver, recorder: recorder,
            prompt: "Reply with exactly: lifecycle works", maxTokens: 32)
        try await waitForDrain(loop: loop, bridge: bridge, recorder: recorder, requestID: requestID)
        let output = try recorder.output(for: requestID)
        try #require(output.failures.isEmpty && output.completions == 1)
        #expect(output.doneCount == 1 && output.finishReasons == ["stop"])
        #expect(output.content.trimmingCharacters(in: .whitespacesAndNewlines) == "lifecycle works")
        #expect(output.reasoning.isEmpty && !output.sawTool)
        let usage = try #require(output.usage)
        #expect(usage.promptTokens > 0 && usage.completionTokens > 0)
        #expect(output.promptTokens == Int(usage.promptTokens))
        #expect(output.completionTokens == Int(usage.completionTokens))
        return .init(content: output.content, finish: output.finishReasons,
                     promptTokens: usage.promptTokens, completionTokens: usage.completionTokens)
    }

    private func observeRealQuietPrefill(
        bridge: EngineV2Bridge, profile: RequestProfileBuilder,
        recorder: FlashNextLifecycleRecorder, requestID: String, priorSteps: Int
    ) async throws -> CBv2CapacitySnapshot {
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while ContinuousClock.now < deadline {
            let capacity = await bridge.capacitySnapshot()
            let state = profile.wireObject()
            let output = try recorder.output(for: requestID)
            try #require(state.firstDeltaUs == nil && output.content.isEmpty
                         && output.reasoning.isEmpty && !output.sawTool,
                         "Lost quiet-prefill observation window; do not relabel a decode cancel")
            try #require(output.terminalCount == 0, "Request finished before the quiet cancellation gate")
            // Two real native launches ensure this is not merely an admission
            // flag: a prior prefill step has advanced before the observed one.
            if capacity.activeRequests == 1 && capacity.activeTokens > 0
                && capacity.stepsExecuted >= priorSteps + 2
                && state.engineSubmitUs != nil && state.engineAdmittedUs != nil
                && (capacity.pagedStorage?.livePageBytes ?? 0) > 0 {
                return capacity
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FlashNextLifecycleFailure("No actual in-progress prefill observed before timeout")
    }

    private func waitForDrain(
        loop: ProviderLoop, bridge: EngineV2Bridge,
        recorder: FlashNextLifecycleRecorder, requestID: String, timeout: Duration = .seconds(120)
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let output = try recorder.output(for: requestID)
            let capacity = await bridge.capacitySnapshot()
            let storage = capacity.pagedStorage
            let providerClean = await loop.flashNextLifecycleRequestIsRetired(requestID)
            let activeRequests = await bridge.activeRequestCount()
            let pendingSubmissions = await bridge._testPendingSubmissionCount()
            let bridgeClean = activeRequests == 0 && pendingSubmissions == 0
            if output.terminalCount == 1 && providerClean && bridgeClean
                && capacity.activeRequests == 0 && capacity.waitingRequests == 0
                && capacity.kvBytesInUse == 0 && capacity.kvBytesReserved == 0
                && storage?.livePageBytes == 0 && storage?.reservedPageBytes == 0 {
                return
            }
            try #require(output.terminalCount <= 1, "Duplicate provider terminal")
            try await Task.sleep(for: .milliseconds(20))
        }
        throw FlashNextLifecycleFailure("Provider/native request ownership did not drain")
    }

    private func requireReleased(
        loop: ProviderLoop, bridge: EngineV2Bridge, owners: FlashNextLifecycleWeakOwners,
        expectedPLE: Qwen4ExpPLEResourceMetrics.Snapshot
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if !owners.isAlive && Qwen4ExpPLEResourceMetrics.snapshot() == expectedPLE { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(!owners.isAlive, "Container or outer/inner target still owned after real unload")
        try #require(Qwen4ExpPLEResourceMetrics.snapshot() == expectedPLE)
        try #require(await bridge.ownedEngine == nil)
        try #require(await loop.hasEngineV2SlotsForTesting() == false)
        try #require(await loop.outstandingKVReservationBytesForTesting() == 0)
        try #require(await loop.loadedModelHashesSnapshot().isEmpty)
    }

    private func verifiedOwnedModel(modelID: String, environment: [String: String]) throws -> ModelInfo {
        let supplied = try #require(environment["DARKBLOOM_QWEN4_REAL_MODEL"])
        let directory = URL(fileURLWithPath: supplied).resolvingSymlinksInPath()
        let resolved = try #require(ModelScanner.resolveLocalPath(modelID: modelID))
        let indexData = try Data(contentsOf: directory.appendingPathComponent("model.safetensors.index.json"))
        let index = try #require(JSONSerialization.jsonObject(with: indexData) as? [String: Any])
        let weights = try #require(index["weight_map"] as? [String: String])
        try #require(!weights.isEmpty)
        for name in Set(weights.values).union(["config.json", "model.safetensors.index.json",
                                                "tokenizer.json", "tokenizer_config.json"]) {
            try #require(!name.contains("/") && name != "..")
            let actual = try FileManager.default.attributesOfItem(
                atPath: resolved.appendingPathComponent(name).resolvingSymlinksInPath().path)
            let expected = try FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent(name).resolvingSymlinksInPath().path)
            try #require(actual[.systemNumber] as? NSNumber == expected[.systemNumber] as? NSNumber)
            try #require(actual[.systemFileNumber] as? NSNumber == expected[.systemFileNumber] as? NSNumber)
        }
        return try #require(ModelScanner.parseModelInfo(snapshotDir: directory, modelName: modelID))
    }
}
