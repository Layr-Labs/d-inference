import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
@testable import ProviderCore

@Suite("Native System One provider", .serialized)
struct SystemOneProviderTests {
    private func loop(models: [ModelInfo]) throws -> ProviderLoop {
        try ProviderLoop(config: .init(
            coordinatorURL: "ws://127.0.0.1:0/unused",
            hardware: .init(machineModel: "native-test", chipName: "Apple M4 Max",
                chipFamily: .m4, chipTier: .max, memoryGb: 128, memoryAvailableGb: 110,
                cpuCores: .init(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 500),
            models: models,
            config: .init(provider: .init(name: "native-decision-test"),
                backend: .init(idleTimeoutMins: 0, maxModelSlots: 3))),
            purgeLegacyFiles: false, attestationSigner: nil)
    }

    @Test func capabilityIsExplicitAndChatTemplateRemainsAbsent() async throws {
        let model = ModelInfo(id: "catalog/decision", modelType: "laya", sizeBytes: 32,
            estimatedMemoryGb: 1, systemOne: true)
        let provider = try loop(models: [model])
        #expect(await provider.isModelAdvertised(model.id))
        #expect(!EngineV2SupportedModels.isSupported(model: model))
        let data = try JSONEncoder().encode(model)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["system_one"] as? Bool == true)
        #expect(json["template_render_ok"] == nil)
        #expect(try JSONDecoder().decode(ModelInfo.self, from: data) == model)
        var ordinary = model
        ordinary.systemOne = false
        let ordinaryJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ordinary)) as? [String: Any])
        #expect(ordinaryJSON["system_one"] == nil)
    }

    @Test func genuineZeroOutputTokensArePreserved() throws {
        let usage = try ProviderLoop.systemOneUsage(Data(#"{"usage":{"input_tokens":123,"output_tokens":0}}"#.utf8))
        #expect(usage.promptTokens == 123)
        #expect(usage.completionTokens == 0)
        #expect(throws: (any Error).self) {
            try ProviderLoop.systemOneUsage(Data(#"{"usage":{"input_tokens":123,"output_tokens":1}}"#.utf8))
        }
    }

    @Test func dispatchRequiresExplicitEncryptedEndpoint() {
        #expect(ProviderLoop.isSystemOneRequest(Data(#"{"endpoint":"/v1/systemone","model":"x"}"#.utf8)))
        #expect(!ProviderLoop.isSystemOneRequest(Data(#"{"model":"x","questions":{}}"#.utf8)))
        #expect(!ProviderLoop.isSystemOneRequest(Data(#"{"endpoint":"/v1/chat/completions"}"#.utf8)))
    }

    @Test func requestOwnerSurvivesCoordinatorCancellationUntilEvaluationExits() async throws {
        let provider = try loop(models: [])
        await provider.setNativeOwnerFixture(request: "cancel-native", model: "native")
        await provider.handleCancellation(requestId: "cancel-native")
        #expect(await provider.hasInflightWork)
        #expect(await provider.nativeOwnerCount() == 1)
        await provider.finishSystemOneRequest(requestId: "cancel-native")
        #expect(await !provider.hasInflightWork)
        #expect(await provider.nativeOwnerCount() == 0)
    }

    @Test func localRouteStaysInsideAuthAndPreservesZeroUsage() async throws {
        let app = makeLocalInferenceApplication(config: .init(port: 0, authToken: "fixture-key"),
            defaultMaxTokens: 1,
            acquire: { throw MultiModelBatchSchedulerEngineError.modelNotLoaded($0) },
            tokenizerProvider: { _ in throw MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization },
            availableModels: { ["decision"] }, mtpSlots: { [] }, systemOne: { _ in
                Data(#"{"model":"decision","answers":{},"usage":{"input_tokens":20,"output_tokens":0}}"#.utf8)
            })
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/systemone", method: .post, body: ByteBuffer(string: "{}")) { response in
                #expect(response.status == .unauthorized)
            }
            try await client.execute(uri: "/v1/systemone", method: .post,
                headers: [.authorization: "Bearer fixture-key"], body: ByteBuffer(string: "{}")) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.accessControlAllowOrigin] == "*")
                #expect(String(buffer: response.body).contains("\"output_tokens\":0"))
            }
        }
    }

    private func makeSnapshot(from source: URL, in snapshots: URL) throws -> URL {
        let fixture = snapshots.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let files = try #require(FileManager.default.enumerator(at: source,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]))
        for case let file as URL in files {
            let relative = String(file.path.dropFirst(source.path.count + 1))
            let destination = fixture.appendingPathComponent(relative)
            if try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: file)
            }
        }
        return fixture
    }

    /// Opt-in hardware integration: the supplied original checkpoint is never modified.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_LAYA_TEST_MODEL_PATH"] != nil))
    func realNativeCheckpointThroughProviderHTTPAndEncryptedTransport() async throws {
        let source = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["DARKBLOOM_LAYA_TEST_MODEL_PATH"]))
        let id = "DarkbloomTest/Laya-" + UUID().uuidString
        let modelDir = ModelDownloader.cacheModelDirectory(for: id)
        let snapshots = modelDir.appendingPathComponent("snapshots")
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        let fixture = try makeSnapshot(from: source, in: snapshots)
        #expect(ModelScanner.resolveLocalPath(modelID: id)?.path == fixture.path)
        defer { try? FileManager.default.removeItem(at: modelDir) }
        let info = try #require(ModelScanner.parseModelInfo(snapshotDir: source, modelName: id))
        #expect(info.systemOne == true)
        #expect(info.templateRenderOK == nil)
        let provider = try loop(models: [info])
        let body = try JSONSerialization.data(withJSONObject: [
            "model": id, "state": "The sky is blue.", "endpoint": "/v1/systemone",
            "questions": ["sky": ["type": "noul", "instructions": "The sky is blue."]],
        ])
        let app = makeLocalInferenceApplication(config: .init(port: 0), defaultMaxTokens: 1,
            acquire: { throw MultiModelBatchSchedulerEngineError.modelNotLoaded($0) },
            tokenizerProvider: { _ in throw MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization },
            availableModels: { [id] }, mtpSlots: { [] },
            systemOne: { try await provider.predictSystemOneForLocal(data: $0) })
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/systemone", method: .post,
                headers: [.contentType: "application/json"], body: ByteBuffer(bytes: body)) { response in
                #expect(response.status == .ok)
                let usage = try ProviderLoop.systemOneUsage(Data(String(buffer: response.body).utf8))
                #expect(usage.promptTokens > 0)
                #expect(usage.completionTokens == 0)
            }
        }
        #expect(await provider.isModelResident(id))
        let idle = try #require(await provider.decisionCapacitySlots().first)
        #expect(idle.numRunning == 0)
        #expect(idle.maxTokensPotential == 0, "An idle slot must not advertise committed work")
        #expect(idle.activeTokenBudgetMax == 32_768)
        #expect(idle.maxConcurrency == 1)
        await provider.setNativeOwnerFixture(request: "busy-owner", model: id)
        let busy = try #require(await provider.decisionCapacitySlots().first)
        #expect(busy.numRunning == 1)
        #expect(busy.maxTokensPotential == busy.activeTokenBudgetMax)
        #expect(busy.activeTokens == 0, "The request bound is not an observed token count")
        #expect(busy.observedDecodeTps == 0)
        #expect(busy.observedPrefillTps == 0)
        #expect(await !provider.unloadModel(id, forEviction: true))
        #expect(await !provider.decisionExclusivityAvailable(modelId: "generative"))
        await provider.finishSystemOneRequest(requestId: "busy-owner")
        #expect(await provider.loadedModelHashesSnapshot()[id]?.isEmpty == false)
        #expect(try await provider.runStartupSelfTestDecode(modelId: id) > .zero)

        let consumer = NodeKeyPair.generate()
        let publicKey = await provider.nativePublicKey()
        let ciphertext = try consumer.encrypt(recipientPublicKey: publicKey, plaintext: body)
        let recorder = NativeOutboundRecorder()
        await provider.handleInferenceRequest(requestId: "native-encrypted", ciphertext: ciphertext,
            senderPublicKey: consumer.publicKeyBytes, cacheReceiptNonce: nil, authenticatedCacheScope: nil,
            send: SendHandle { recorder.record($0) })
        for _ in 0..<1000 {
            if recorder.hasTerminal { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(recorder.completion?.completionTokens == 0)
        #expect(recorder.completion?.promptTokens ?? 0 > 0)
        let payload = try #require(recorder.chunk)
        let decoded = try consumer.decrypt(senderPublicKey: publicKey,
            ciphertext: try #require(Data(base64Encoded: payload.ciphertext)))
        #expect(try ProviderLoop.systemOneUsage(decoded).completionTokens == 0)
        for _ in 0..<200 {
            if await !provider.hasInflightWork { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await provider.unloadModel(id))
        #expect(await !provider.isModelResident(id))
        #expect(await provider.nativeOwnerCount() == 0)
        #expect(await provider.outstandingKVReservationBytesForTesting() == 0)
    }
}

private extension ProviderLoop {
    func nativePublicKey() -> Data { keyPair.publicKeyBytes }
    func nativeOwnerCount() -> Int { decisionRequestOwners.count }
    func setNativeOwnerFixture(request: String, model: String) {
        decisionRequestOwners[request] = model
        requestToModel[request] = model
    }
}

private final class NativeOutboundRecorder: @unchecked Sendable {
    let lock = NSLock()
    private var messages: [OutboundMessage] = []
    func record(_ message: OutboundMessage) { lock.withLock { messages.append(message) } }
    var hasTerminal: Bool { lock.withLock { messages.contains {
        if case .inferenceComplete = $0 { return true }
        if case .inferenceError = $0 { return true }
        return false
    } } }
    var completion: UsageInfo? { lock.withLock { messages.compactMap {
        if case .inferenceComplete(_, let usage, _, _, _, _) = $0 { return usage }; return nil
    }.first } }
    var chunk: EncryptedPayload? { lock.withLock { messages.compactMap {
        if case .inferenceChunk(_, _, let encrypted) = $0 { return encrypted }; return nil
    }.first } }
}
