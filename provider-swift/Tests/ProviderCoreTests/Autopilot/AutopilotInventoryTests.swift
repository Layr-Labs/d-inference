import Foundation
import Testing
@testable import ProviderCore

@Suite("Autopilot inventory isolation", .serialized)
struct AutopilotInventoryTests {
    private let selected = ModelInfo(id: "gpt-oss-20b", modelType: "gpt_oss", sizeBytes: 1024, estimatedMemoryGb: 2, weightHash: "selected-hash")
    private let cached = ModelInfo(id: "qwen3.5-9b", modelType: "qwen3_5", sizeBytes: 2048, estimatedMemoryGb: 4, weightHash: "cached-hash")
    private var hardware: HardwareInfo {
        HardwareInfo(machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
            memoryGb: 128, memoryAvailableGb: 124, cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546)
    }
    private func control(shadow: Bool, expiry: Int64? = nil) -> ModelAutopilotControl {
        .init(sessionId: "session", revision: "inventory", enabled: true,
            expiresAtMs: expiry ?? Int64(Date().timeIntervalSince1970 * 1000) + 120_000, observeOnly: shadow)
    }
    private func loop() throws -> ProviderLoop {
        let settings = ModelAutopilotSettings(enabled: true, consentRecorded: true,
            selectedModels: [selected.id, cached.id], revision: "inventory")
        return try ProviderLoop(config: .init(coordinatorURL: "ws://127.0.0.1:0/unused", hardware: hardware,
            models: [selected], config: .init(provider: .init(name: "inventory-test"),
                backend: .init(enabledModels: [selected.id], modelAutopilot: settings)),
            autopilotInventory: [selected, cached]), attestationSigner: nil)
    }

    @Test func waitingAndShadowDoNotGrantLoadPermissionOrChangeReserve() async throws {
        let loop = try loop()
        await loop.publishModelAutopilotSnapshot()
        let reserve = await loop.resolvedActivationReserveBytes
        for shadow in [false, true] {
            if shadow { await loop.handleAutopilotControl(control(shadow: true)) }
            #expect(await loop.advertisedModels.keys.sorted() == [selected.id])
            #expect(await loop.resolvedActivationReserveBytes == reserve)
            #expect(await loop.maxModelSlots == 1)
            #expect(await loop.state.modelAutopilot?.maxModelSlots == 2)
            #expect(await loop.autopilotAllowsModel(cached.id) == false)
            #expect(await loop.autopilotAllowsModel(selected.id))
            #expect(await loop.state.modelAutopilot?.selectedModels == [selected.id, cached.id])
            let replies = AutopilotRecorder()
            await loop.handleLoadModelRequest(modelId: cached.id, send: .init(replies.append))
            #expect(replies.legacyStatuses == [.failed])
            #expect(await loop.preloadTasks.isEmpty)
            do {
                try await loop.ensureModelLoaded(modelId: cached.id)
                Issue.record("An observational candidate reached the model loader")
            } catch InferenceError.modelLoadFailed(let reason) {
                #expect(reason == "model_not_selected")
            } catch { Issue.record("Unexpected load refusal: \(error)") }
        }
        await loop.idleMonitorTask?.cancel()
    }

    @Test func selectedModelSuccessorDoesNotRequireAutopilotInventoryConsent() async throws {
        let loop = try loop()
        await loop.handleAutopilotControl(control(shadow: true))
        let successor = "selected-model-next-build"
        let unrelated = "unrelated-next-build"
        #expect(await loop.autopilotSettings.selectedModels.contains(successor) == false)
        await loop.reconcileDesiredModels([
            .init(modelName: "selected-alias", desiredBuild: successor, previousBuild: selected.id),
            .init(modelName: "unrelated-alias", desiredBuild: unrelated, previousBuild: cached.id),
        ], send: SendHandle { _ in })
        #expect(await loop.autopilotAllowsModel(successor))
        #expect(await loop.desiredPrefetchTargets.contains(successor))
        #expect(await loop.desiredSwapDrop[successor] == selected.id)
        #expect(await loop.autopilotAllowsModel(unrelated) == false)
        #expect(await loop.autopilotAllowsModel(cached.id) == false)
        #expect(await loop.advertisedModels[successor] == nil)
        #expect(await loop.autopilotSettings.selectedModels.contains(successor) == false)
        #expect(await loop.modelSlots.isEmpty)
        await loop.idleMonitorTask?.cancel()
    }

    @Test func encryptedNetworkAndLocalRequestsCannotLoadUnselectedInventory() async throws {
        let loop = try loop()
        await loop.handleAutopilotControl(control(shadow: true))
        let sender = NodeKeyPair.generate()
        let request = try JSONSerialization.data(withJSONObject: [
            "model": cached.id, "messages": [["role": "user", "content": "fixture"]],
            "max_tokens": 1, "stream": true, "reasoning_parser": "none",
        ])
        let encrypted = try sender.encrypt(recipientPublicKey: await loop.keyPair.publicKeyBytes, plaintext: request)
        let recorder = InventoryInferenceRecorder()
        await loop.handleInferenceRequest(requestId: "inventory-isolation", ciphertext: encrypted,
            senderPublicKey: sender.publicKeyBytes, cacheReceiptNonce: nil, authenticatedCacheScope: "isolated-test",
            send: SendHandle(recorder.record))
        #expect(recorder.accepted == 0)
        #expect(recorder.errors == 1)
        #expect(await loop.modelSlots.isEmpty)
        #expect(await loop.modelsLoading.isEmpty)
        do {
            try await loop.throwIfRefusingNewLocalWork(modelId: cached.id)
            Issue.record("Local request bypassed serving selection")
        } catch { #expect(error.localizedDescription.contains("model_not_selected")) }
        await loop.idleMonitorTask?.cancel()
    }

    @Test func liveLeaseRequiresOwnedTargetPublicationAndExpiryRestoresSelection() async throws {
        let loop = try loop()
        await loop.handleAutopilotControl(control(shadow: false))
        #expect(await loop.autopilotAllowsModel(cached.id))
        #expect(await loop.advertisedModels[cached.id] == nil)
        #expect(await loop.modelSlots.isEmpty)
        let command = ModelAutopilotCommand(commandId: "target", loadModelId: cached.id,
            expiresAtMs: Int64(Date().timeIntervalSince1970 * 1000) + 60_000,
            sessionId: "session", revision: "inventory")
        await loop.installInventoryCommandForTesting(command)
        try await loop.preflightAutopilotTarget(command)
        try await loop.prepareAutopilotTarget(command)
        #expect(await loop.advertisedModels[cached.id] != nil)
        #expect(await loop.pendingAdvertise.isEmpty)
        let required = await loop.resolvedActivationReserveBytes
        #expect(await loop.kvBudget.memoryHeadroomSnapshot().activationReserveBytes >= required)
        await loop.handleAutopilotControl(control(shadow: false, expiry: 1))
        // Accepted work retains the published target until it finishes.
        #expect(await loop.advertisedModels[cached.id] != nil)
        await loop.finishInventoryCommandForTesting()
        #expect(await loop.autopilotAllowsModel(cached.id) == false)
        #expect(await loop.advertisedModels.keys.sorted() == [selected.id])
        await loop.handleAutopilotControl(control(shadow: false))
        await loop.clearAutopilotControl()
        #expect(await loop.autopilotAllowsModel(cached.id) == false)
        #expect(await loop.advertisedModels.keys.sorted() == [selected.id])
        await loop.idleMonitorTask?.cancel()
    }

    @Test(arguments: [false, true]) func registrationAndReconnectKeepInventorySeparate(attested: Bool) throws {
        let config = CoordinatorClientConfig(url: "ws://127.0.0.1:0/unused", hardware: hardware,
            models: [selected], backendName: "mlx-swift", attestation: attested ? RawJSON(rawBytes: Data("{}".utf8)) : nil, autopilotInventory: [selected, cached])
        var state = ModelAutopilotSnapshot(enabled: true)
        state.selectedModels = [selected.id, cached.id]
        state.revision = "inventory"
        for active in [false, true] {
            state.active = active
            let data = try CoordinatorClientCodec.encodeRegistration(from: config, models: [selected, cached], modelAutopilot: state)
            let message = try ProviderProtocolCodec.decodeProviderMessage(from: data)
            guard case .register(let registration) = message else { Issue.record("not register"); return }
            #expect(registration.models.map(\.id) == [selected.id])
            #expect(registration.autopilotInventory?.map(\.id) == [selected.id, cached.id])
            #expect(registration.modelAutopilot?.protocolVersion == 3)
        }
        let changed = CoordinatorClientCodec.registrationMessage(from: config, models: [cached],
            modelAutopilot: state, ordinaryServingModelIDs: [cached.id])
        guard case .register(let registration) = changed else { Issue.record("not register"); return }
        #expect(registration.models.map(\.id) == [cached.id])
    }
}

private final class InventoryInferenceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [OutboundMessage] = []
    func record(_ value: OutboundMessage) { lock.withLock { values.append(value) } }
    var accepted: Int { lock.withLock { values.filter { if case .inferenceAccepted = $0 { return true }; return false }.count } }
    var errors: Int { lock.withLock { values.filter { if case .inferenceError = $0 { return true }; return false }.count } }
}

private extension ProviderLoop {
    func installInventoryCommandForTesting(_ command: ModelAutopilotCommand) {
        autopilotCommand = command
        autopilotMutationStarted = true
    }
    func finishInventoryCommandForTesting() {
        autopilotCommand = nil
        autopilotMutationStarted = false
        withdrawInactiveAutopilotModels()
    }
}
