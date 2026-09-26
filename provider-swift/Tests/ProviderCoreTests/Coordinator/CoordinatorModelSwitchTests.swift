import Foundation
import Testing
@testable import ProviderCore

private func switchTransportModel(_ id: String) -> ModelInfo {
    ModelInfo(id: id, modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 1, weightHash: "hash-\(id)")
}

private func switchTransportClient(_ url: String) -> CoordinatorClient {
    CoordinatorClient(
        config: CoordinatorClientConfig(
            url: url,
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                memoryGb: 128, memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546),
            models: [switchTransportModel("old")], backendName: "mlx-swift",
            heartbeatInterval: 60, publicKey: "cHVibGlj"),
        stats: AtomicProviderStats(), state: ProviderState(), liveAPNsToken: { nil })
}

@Suite("Coordinator model replacement transport")
struct CoordinatorModelSwitchTests {
    @Test(arguments: [false, true], [false, true])
    func unknownOutcomePreservesPhaseInventory(dropConnection: Bool, validateOnly: Bool) async throws {
        let mock = MockCoordinator(acknowledgeModelReplacements: false)
        let url = try await mock.start()
        defer { Task { await mock.shutdown() } }
        let client = switchTransportClient(url.mockProviderWebSocketURL())
        let (events, _) = await client.start()
        defer { Task { await client.shutdown() } }
        for await event in events { if case .connected = event { break } }
        let reader = Task {
            for await event in events {
                if case .drainAck(let id) = event { await client.completeDrainAcknowledgement(id) }
            }
        }
        defer { reader.cancel() }
        let drain = try #require(await client.prepareModelSwitch(timeout: .seconds(2)))
        await client.stageModelSelection([switchTransportModel("old")])
        let replacement = Task { () -> ModelSwitchError? in
            do {
                if validateOnly {
                    try await client.validateModelSelectionAfterDrain(
                        [switchTransportModel("new")], drainID: drain,
                        timeout: dropConnection ? .seconds(5) : .milliseconds(100))
                } else {
                    try await client.replaceModelsAfterDrain(
                        [switchTransportModel("new")], drainID: drain,
                        timeout: dropConnection ? .seconds(5) : .milliseconds(100))
                }
                return nil
            } catch { return error as? ModelSwitchError }
        }
        _ = try #require(try await mock.waitForSnapshot { !$0.modelsReplacements.isEmpty })
        if dropConnection { await mock.dropActiveWebSocket() }
        #expect(await replacement.value == (dropConnection ? .disconnected : .timedOut))
        let expected = validateOnly ? "old" : "new"
        #expect(await client.currentAdvertisedModels().map(\.id) == [expected])
        #expect(await client.modelWeightHashOverrides == [expected: "hash-\(expected)"])
        #expect(await client.modelReplacement == nil)
        if !dropConnection {
            #expect(mock.snapshot().registers.count == 1)
            #expect(await client.acknowledgedSwitchDrain == drain)
        }
    }

    @Test(arguments: [false, true])
    func wrongCorrelationCannotRejectOrAcceptReplacement(validateOnly: Bool) async throws {
        let mock = MockCoordinator(acknowledgeModelReplacements: false)
        let url = try await mock.start()
        defer { Task { await mock.shutdown() } }
        let client = switchTransportClient(url.mockProviderWebSocketURL())
        let (events, _) = await client.start()
        defer { Task { await client.shutdown() } }
        for await event in events { if case .connected = event { break } }
        let reader = Task {
            for await event in events {
                if case .drainAck(let id) = event { await client.completeDrainAcknowledgement(id) }
            }
        }
        defer { reader.cancel() }
        let drain = try #require(await client.prepareModelSwitch(timeout: .seconds(2)))
        await client.stageModelSelection([switchTransportModel("old")])
        let replacement = Task {
            if validateOnly {
                try await client.validateModelSelectionAfterDrain([switchTransportModel("new")], drainID: drain, timeout: .seconds(2))
            } else {
                try await client.replaceModelsAfterDrain([switchTransportModel("new")], drainID: drain, timeout: .seconds(2))
            }
        }
        let captured = try #require(try await mock.waitForSnapshot { !$0.modelsReplacements.isEmpty })
        let request = try #require(captured.modelsReplacements.first)
        let expected = validateOnly ? "old" : "new"
        #expect(await client.currentAdvertisedModels().map(\.id) == [expected])
        #expect(await client.modelWeightHashOverrides == [expected: "hash-\(expected)"])
        try await mock.pushModelsReplaceAck(.init(requestId: request.requestId, drainRequestId: "wrong", validateOnly: validateOnly, accepted: false, error: "invalid_models"))
        try await mock.pushModelsReplaceAck(.init(requestId: "wrong", drainRequestId: drain, validateOnly: validateOnly, accepted: false, error: "invalid_models"))
        try await mock.pushModelsReplaceAck(.init(requestId: request.requestId, drainRequestId: drain, validateOnly: !validateOnly, accepted: false, error: "invalid_models"))
        try await mock.pushModelsReplaceAck(.init(requestId: request.requestId, drainRequestId: drain, validateOnly: validateOnly, accepted: true))
        try await replacement.value
        #expect(await client.currentAdvertisedModels().map(\.id) == [expected])
        #expect(await client.modelWeightHashOverrides == [expected: "hash-\(expected)"])
        #expect(mock.snapshot().registers.count == 1)
        #expect(await client.acknowledgedSwitchDrain == (validateOnly ? drain : nil))
    }

    @Test(arguments: [false, true])
    func validationPreservesInventoryAndDrainForCommitOrRollback(reject: Bool) async throws {
        let mock = MockCoordinator(rejectedReplacementModelIDs: reject ? ["new"] : [])
        let url = try await mock.start()
        defer { Task { await mock.shutdown() } }
        let client = switchTransportClient(url.mockProviderWebSocketURL())
        let (events, _) = await client.start()
        defer { Task { await client.shutdown() } }
        for await event in events { if case .connected = event { break } }
        let reader = Task {
            for await event in events {
                if case .drainAck(let id) = event { await client.completeDrainAcknowledgement(id) }
            }
        }
        defer { reader.cancel() }
        await client.stageModelSelection([switchTransportModel("old")])
        let drain = try #require(await client.prepareModelSwitch(timeout: .seconds(2)))
        var validationError: ModelSwitchError?
        do {
            try await client.validateModelSelectionAfterDrain([switchTransportModel("new")], drainID: drain, timeout: .seconds(2))
        } catch { validationError = try #require(error as? ModelSwitchError) }
        #expect(validationError == (reject ? .invalidModels : nil))
        #expect(await client.currentAdvertisedModels().map(\.id) == ["old"])
        #expect(await client.modelWeightHashOverrides == ["old": "hash-old"])
        #expect(await client.acknowledgedSwitchDrain == drain)
        let selected = reject ? "old" : "new"
        try await client.replaceModelsAfterDrain([switchTransportModel(selected)], drainID: drain, timeout: .seconds(2))
        #expect(await client.currentAdvertisedModels().map(\.id) == [selected])
        #expect(await client.modelWeightHashOverrides == [selected: "hash-\(selected)"])
        #expect(await client.acknowledgedSwitchDrain == nil)
        #expect(mock.snapshot().registers.count == 1)
    }
}
