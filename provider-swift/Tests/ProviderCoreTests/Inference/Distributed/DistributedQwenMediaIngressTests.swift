import Foundation
import Testing
import DarkbloomClusterProtocol
import MLXLMCommon
import MLXLMServer
@testable import ProviderCore

@Suite("Qwen distributed media preprocessing", .serialized)
struct DistributedQwenMediaIngressTests {
    private func configuration() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model_type": "qwen3_5", "image_token_id": 60, "video_token_id": 61,
            "vision_start_token_id": 57, "vision_end_token_id": 58,
            "text_config": ["model_type": "qwen3_5_text", "hidden_size": 8,
                "num_hidden_layers": 1, "intermediate_size": 16, "num_attention_heads": 1,
                "num_key_value_heads": 1, "head_dim": 8, "linear_num_key_heads": 1,
                "linear_num_value_heads": 1, "linear_key_head_dim": 8,
                "linear_value_head_dim": 8, "linear_conv_kernel_dim": 2,
                "vocab_size": 64, "full_attention_interval": 1],
            "vision_config": ["model_type": "qwen3_5_vision", "depth": 1,
                "hidden_size": 8, "intermediate_size": 16, "out_hidden_size": 8,
                "num_heads": 2, "patch_size": 16, "spatial_merge_size": 2,
                "temporal_patch_size": 2, "num_position_embeddings": 16,
                "in_channels": 3, "hidden_act": "gelu_pytorch_tanh", "deepstack_visual_indexes": []]
        ], options: [.sortedKeys])
    }
    private var processor: Data {
        Data(#"{"image_processor_type":"Qwen3VLImageProcessor","patch_size":16,"merge_size":2,"temporal_patch_size":2,"image_mean":[0.5,0.5,0.5],"image_std":[0.5,0.5,0.5],"min_pixels":1024,"max_pixels":4096}"#.utf8)
    }
    private func ingress(maximum: Int = 1024) throws -> DistributedQwenMediaIngress {
        let bytes = try configuration()
        return try .init(configuration: bytes, processorConfiguration: processor,
            artifactSHA256: String(repeating: "a", count: 64),
            expectedConfigurationSHA256: ClusterQwenMedia.sha256(bytes), maximumPromptTokens: maximum)
    }
    private func budget(total: UInt64 = 128 << 30) -> GlobalKVCacheBudget {
        .init(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: total, active: 0, cache: 0, systemAvailable: total) })
    }
    private func request(_ media: [(String, String)], role: String = "user") throws -> OpenAIChatCompletionRequest {
        let parts: [[String: Any]] = media.map { kind, encoded in
            let type = kind + "_url", mime = kind == "image" ? "image/png" : "video/mp4"
            return ["type": type, type: ["url": "data:" + mime + ";base64," + encoded]]
        } + [["type": "text", "text": "Name these colors."]]
        let data = try JSONSerialization.data(withJSONObject: ["model": "EigenLabs/Qwen3.8-27B-4bit-mtp",
            "messages": [["role": role, "content": parts]], "max_tokens": 4])
        return try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: data)
    }

    @Test func actualImageAndVideoProcessorProduceBoundedIndependentWire() async throws {
        let ingress = try ingress(), budget = budget()
        var retained: [ClusterQwenMedia] = []
        for items in [[("image", QwenIngressFixtures.red)], [("image", QwenIngressFixtures.blue)],
            [("image", QwenIngressFixtures.red), ("image", QwenIngressFixtures.blue)],
            [("video", QwenIngressFixtures.video)], [("image", QwenIngressFixtures.red)]] {
            let prepared = try await ingress.prepare(request: request(items), controls: .init(),
                tokenizer: QwenIngressTokenizer(), hostBudget: budget)
            #expect(await budget.outstandingReservedBytes() == DistributedQwenMediaHostMemory.wireBytes)
            let media = try await prepared.lifetime.withSubmission(requestID: UUID().uuidString) { wire, _ in
                let media = try ClusterQwenMedia.decodeBounded(wire)
                try media.verifyEncodedBytes()
                return media.withoutEncodedBytes
            }
            #expect(media.items.count == items.count)
            #expect(media.promptLength == prepared.tokens.count)
            #expect(media.promptSHA256 == ClusterQwenMedia.int32SHA256(prepared.tokens.map(Int32.init)))
            #expect(media.processorSHA256 == ClusterQwenMedia.sha256(processor))
            #expect(media.items.allSatisfy { $0.decodedPixels == 224 * 224 && $0.height.isMultiple(of: 2) && $0.width.isMultiple(of: 2) })
            #expect(await budget.outstandingReservedBytes() == 0)
            retained.append(media)
        }
        #expect(retained[0] == retained[4])
        #expect(retained[0].items[0].patchesSHA256 != retained[1].items[0].patchesSHA256)
        #expect(retained[2].items.map(\.patchesSHA256) == [retained[0].items[0].patchesSHA256, retained[1].items[0].patchesSHA256])
        #expect(retained[3].items[0].kind == .video && retained[3].items[0].temporal > 1)
    }

    @Test func invalidRoleMalformedMediaAndExpandedPromptRefuseWithoutLeakingCharge() async throws {
        for (request, maximum) in [(try request([("image", QwenIngressFixtures.red)], role: "system"), 1024),
            (try request([("image", "AAAA")]), 1024),
            (try request([("image", QwenIngressFixtures.red)]), 2)] {
            let budget = budget(), ingress = try ingress(maximum: maximum)
            await #expect(throws: (any Error).self) {
                try await ingress.prepare(request: request, controls: .init(), tokenizer: QwenIngressTokenizer(), hostBudget: budget)
            }
            #expect(await budget.outstandingReservedBytes() == 0)
        }
    }

    @Test func hostMemoryRefusesBeforeDecodeAndWrongIdentityCannotPrepare() async throws {
        let budget = budget(total: 1 << 20), ingress = try ingress()
        await #expect(throws: (any Error).self) {
            try await ingress.prepare(request: request([("image", QwenIngressFixtures.red)]), controls: .init(),
                tokenizer: QwenIngressTokenizer(), hostBudget: budget)
        }
        #expect(await budget.outstandingReservedBytes() == 0)
        #expect(throws: (any Error).self) {
            try DistributedQwenMediaIngress(configuration: configuration(), processorConfiguration: processor,
                artifactSHA256: String(repeating: "a", count: 64), expectedConfigurationSHA256: String(repeating: "b", count: 64), maximumPromptTokens: 1024)
        }
    }
    private func bridge(_ owner: QwenIngressOwner, budget: GlobalKVCacheBudget) throws -> (EngineV2Bridge, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try configuration().write(to: directory.appendingPathComponent("config.json"))
        try processor.write(to: directory.appendingPathComponent("preprocessor_config.json"))
        do {
            let bridge = try DistributedEngineFactory.makeBridge(owner: owner, expectedIdentity: owner.identity,
                profile: owner.profile, tokenizer: TokenizerHandle(QwenIngressTokenizer()), eosTokenIDs: [63],
                publicModelID: "EigenLabs/Qwen3.8-27B-4bit-mtp", modelType: "qwen3_5",
                modelDirectory: directory, mediaHostBudget: budget)
            return (bridge, directory)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    @Test func actualBridgeKeepsIndependentWireUntilEachNativeRetirement() async throws {
        let owner = try QwenIngressOwner(configuration: configuration()), budget = budget()
        let (bridge, directory) = try bridge(owner, budget: budget)
        defer { try? FileManager.default.removeItem(at: directory) }
        var streams: [AsyncStream<GenerationEvent>] = []
        for (index, color) in [QwenIngressFixtures.red, QwenIngressFixtures.blue].enumerated() {
            let prepared = try await ingress().prepare(request: request([("image", color)]), controls: .init(),
                tokenizer: QwenIngressTokenizer(), hostBudget: budget)
            let stream = try await prepared.lifetime.withSubmission(requestID: "media-\(index)") { wire, _ in
                try await bridge.submitTokenized(promptTokens: prepared.tokens,
                    request: ChatCompletionRequest(model: "EigenLabs/Qwen3.8-27B-4bit-mtp", messages: [], temperature: 0, max_tokens: 1),
                    requestId: "media-\(index)", cacheEnabled: false, clusterQwenMedia: wire,
                    qwenMediaLifetime: prepared.lifetime, firstContentDeadline: nil)
            }
            streams.append(stream)
        }
        #expect(owner.leases.count == 2)
        #expect(await budget.outstandingReservedBytes() == DistributedQwenMediaHostMemory.wireBytes * 2)
        #expect(owner.leases.allSatisfy { $0.holdsWire })
        owner.leases[0].send(.token(4))
        await bridge.cancel(requestId: "media-1")
        #expect(await budget.outstandingReservedBytes() == DistributedQwenMediaHostMemory.wireBytes * 2)
        owner.leases[1].acknowledge()
        for await _ in streams[1] {}
        for _ in 0..<1000 {
            if await budget.outstandingReservedBytes() == DistributedQwenMediaHostMemory.wireBytes { break }
            await Task.yield()
        }
        #expect(await budget.outstandingReservedBytes() == DistributedQwenMediaHostMemory.wireBytes)
        #expect(!owner.leases[1].holdsWire && owner.leases[0].holdsWire)
        owner.leases[0].acknowledge()
        for await _ in streams[0] {}
        await bridge.shutdown()
        #expect(await budget.outstandingReservedBytes() == 0)
        #expect(owner.leases.allSatisfy { !$0.holdsWire && $0.releases == 1 })
    }

    @Test func factoryCannotInferMediaFromTheModelNameOrForeignReadiness() async throws {
        let plain = try QwenIngressOwner(configuration: configuration(), contract: nil)
        let (bridge, directory) = try bridge(plain, budget: budget())
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(await bridge.clusterQwenMediaIngress == nil)
        await bridge.shutdown()
        let foreign = try QwenIngressOwner(configuration: configuration(), modelID: "foreign-model")
        #expect(throws: (any Error).self) { try self.bridge(foreign, budget: budget()) }
    }

    @Test func schedulerRoutesRealImageAndVideoThroughTheOwnedBridge() async throws {
        let owner = try QwenIngressOwner(configuration: configuration()), budget = budget()
        let (bridge, directory) = try bridge(owner, budget: budget)
        defer { try? FileManager.default.removeItem(at: directory) }
        let releases = QwenIngressReleaseCounter()
        let model = "EigenLabs/Qwen3.8-27B-4bit-mtp"
        let entry = MultiModelBatchSchedulerEngine.ModelRegistryEntry(
            tokenizer: TokenizerHandle(QwenIngressTokenizer()), modelType: "qwen3_5",
            isVLM: true, engineV2Bridge: bridge)
        let scheduler = MultiModelBatchSchedulerEngine(registryProvider: { [model: entry] },
            releaseModel: { _ in await releases.increment() })
        for (index, media) in [("image", QwenIngressFixtures.red), ("video", QwenIngressFixtures.video)].enumerated() {
            let stream = try await scheduler.streamChatCompletion(request: request([media]))
            #expect(owner.leases.count == index + 1)
            #expect(owner.leases[index].holdsWire)
            #expect(await budget.outstandingReservedBytes() == DistributedQwenMediaHostMemory.wireBytes)
            for token in 4...7 { owner.leases[index].send(.token(token)) }
            owner.leases[index].acknowledge()
            var text = "", completionCount: Int?
            for try await event in stream {
                if case .content(let value) = event { text += value }
                if case .info(let value) = event { completionCount = value.completionTokens }
            }
            #expect(text == "4,5,6,7")
            #expect(completionCount == 4)
            #expect(await releases.value == index + 1)
            #expect(await budget.outstandingReservedBytes() == 0)
            #expect(!owner.leases[index].holdsWire)
        }
        // Explicit schema requests cannot silently become unconstrained text.
        var json = try request([("image", QwenIngressFixtures.red)])
        json.responseFormat = .jsonObject()
        await #expect(throws: (any Error).self) { try await scheduler.streamChatCompletion(request: json) }
        #expect(owner.leases.count == 2)
        #expect(await releases.value == 3)
        #expect(await budget.outstandingReservedBytes() == 0)
        await bridge.shutdown()
    }

}
