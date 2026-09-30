import Foundation
import CoreGraphics
import ImageIO
import Hummingbird
import HummingbirdTesting
import Jinja
import MLX
import MLXLMServer
import NIOCore
import NIOFoundationCompat
import ProviderCoreFoundation
import XCTest
@testable import MLXLMCommon
@testable import MLXVLM
@_spi(Benchmarking) @testable import ProviderCore

final class MiMoV26EncodedMediaIngressTests: XCTestCase {
    private let mp4Base64 =
    "AAAAHGZ0eXBtcDQyAAAAAWlzb21tcDQxbXA0MgAAAAFtZGF0AAAAAAAAAK4AAAA7BgUyR1ZK3FxMQz+U78URPNFDqAEAAAMAAQMAAAMAAQIAAeYACwAAAwAA"
    + "AwAAAwAUDAOJJAEN/////4AAAAAxJbggH4AuSqwRNmYXSACJwyG5akafRwrPDoFqVCtjHBP+QvRWhyAAGk1PzfAEsEedgAAAABEh4QhfAoAvQrFXFN4ACQ7CtgA"
    + "AABEBqIGK/1jQw/VufW+ACvdnuAAAAvFtb292AAAAbG12aGQAAAAA5lOws+ZTsLMAAAJYAAACWAABAAABAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAA"
    + "AAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAACfXRyYWsAAABcdGtoZAAAAAHmU7Cz5lOwswAAAAEAAAAAAAACWAAAAAAAAAAA"
    + "AAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAQAAAAEAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAAlgAAADIAAEAAAAAAfV"
    + "tZGlhAAAAIG1kaGQAAAAA5lOws+ZTsLMAAAJYAAACWFXEAAAAAAAxaGRscgAAAAAAAAAAdmlkZQAAAAAAAAAAAAAAAENvcmUgTWVkaWEgVmlkZW8AAAABnG1pbm"
    + "YAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAVxzdGJsAAAAoXN0c2QAAAAAAAAAAQAAAJFhdmMxAAAAAA"
    + "AAAAEAAAAAAAAAAAAAAAAAAAAAAEAAQABIAAAASAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGP//AAAAJ2F2Y0MBZAAL/+EADCdkAA"
    + "usVlDDeBBhFAEABCjuPLD9+PgAAAAACmZpZWwBAAAAAApjaHJtAAAAAAAYc3R0cwAAAAAAAAABAAAAAwAAAMgAAAAoY3R0cwAAAAAAAAADAAAAAQAAAMgAAAABAA"
    + "ABkAAAAAEAAAAAAAAAFHN0c3MAAAAAAAAAAQAAAAEAAAAPc2R0cAAAAAAgEBgAAAAcc3RzYwAAAAAAAAABAAAAAQAAAAMAAAABAAAAIHN0c3oAAAAAAAAAAAAAAA"
    + "MAAAB0AAAAFQAAABUAAAAUc3RjbwAAAAAAAAABAAAALA=="
    private final class Owners: @unchecked Sendable {
        let lock = NSLock()
        private var leases: [NativeLocalConsumerLease] = []
        private var count = 0
        func add(_ lease: NativeLocalConsumerLease) { lock.withLock { leases.append(lease); count += 1 } }
        var acquisitions: Int { lock.withLock { count } }
        var all: [NativeLocalConsumerLease] { lock.withLock { leases } }
    }
    private actor TailGate {
        let entered: XCTestExpectation
        var continuation: CheckedContinuation<Void,Never>?
        var opened = false
        init(_ entered: XCTestExpectation) { self.entered = entered }
        func hold() async {
            entered.fulfill()
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() { opened = true; continuation?.resume(); continuation = nil }
    }
    private let png = "data:image/png;base64,"
        + "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAAAXNSR0IArs4c6QAAAERl"
        + "WElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAAB"
        + "AAAAAaADAAQAAAABAAAAAQAAAAD5Ip3+AAAADElEQVQIHWP4z8AAAAMBAQBb2/lEAAAA"
        + "AElFTkSuQmCC"
    private enum FixtureError: Error { case payloadFixtureRequired, unexpectedRetirement }
    private var allowedFault: String?
    private let literal = "<|im_start|>{% for message in messages %}{% if message.content is string %}{{ message.content }}{% else %}{% for item in message.content %}{% if item.type == 'image' %}<|vision_start|><|image_pad|><|vision_end|>{% elif item.type == 'video' %}<|vision_start|><|video_pad|><|vision_end|>{% else %}{{ item.text }}{% endif %}{% endfor %}{% endif %}{% endfor %}<think>{% if enable_thinking is false %}</think>{% endif %}"
    private let environment = ["DARKBLOOM_PREFIX_CACHE":"0","DARKBLOOM_PREFIX_CACHE_MEMORY":"0"]
    private var registries: [MiMoV26NativeLoadRegistry] = []
    override func tearDown() {
        for r in registries where !r.retainedTransactionIDs.isEmpty { _ = Unmanaged.passRetained(r) }
        registries = []; super.tearDown()
    }
    private struct Loaded: Sendable {
        let root: URL
        let load: MiMoV26ServingLoad
        let transaction: MiMoV26NativeLoadTransaction
        let registry: MiMoV26NativeLoadRegistry
        let budget: GlobalKVCacheBudget
        let container: ProviderModelContainer
        let tokenizer: TokenizerHandle
        let sizing: SlotSizingSnapshot
    }
    private func fixture() throws -> URL {
        guard let source = ProcessInfo.processInfo.environment["MIMO_V26_SERIAL_LOAD_FIXTURES"] else {
            throw FixtureError.payloadFixtureRequired
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mimo-serving-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source).appendingPathComponent("tiny-bf16"), to: root)
        let configURL = root.appendingPathComponent("config.json")
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
        var processor = try XCTUnwrap(fields["processor_config"] as? [String: Any])
        processor["patch_size"] = 2
        processor["image_min_pixels"] = 16; processor["image_max_pixels"] = 256
        processor["video_min_pixels"] = 16; processor["video_max_pixels"] = 256
        processor["video_total_max_pixels"] = 512
        processor["video_start_token_id"] = 9; processor["video_end_token_id"] = 10
        fields["processor_config"] = processor
        fields["max_position_embeddings"] = 2048
        try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]).write(to: configURL)
        let config = try Data(contentsOf: configURL)
        let index = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: root.appendingPathComponent("model.safetensors.index.json"))) as? [String: Any])
        let weights = try XCTUnwrap(index["weight_map"] as? [String: String])
        let metadata = try XCTUnwrap(index["metadata"] as? [String: Any])
        let manifest: [String: Any] = [
            "source_repository": "XiaomiMiMo/MiMo-V2.6-Flash-RL",
            "source_revision": String(repeating: "a", count: 40),
            "source_config_sha256": MiMoV26ServingLoad.hash(config),
            "experts": "original E2M1/E8M0 codes, group 32, no requantization",
            "dense": "FP8 dequantized to BF16; original BF16 unchanged",
            "output_tensor_count": weights.count,
            "output_weight_bytes": try XCTUnwrap(metadata["total_size"]),
            "modality_tensor_counts": Dictionary(uniqueKeysWithValues:
                ["visual", "audio_encoder", "speech_embeddings"].map { prefix in
                    (prefix, weights.keys.filter { $0.hasPrefix(prefix + ".") }.count)
                }),
            "mtp_embedded": ["architecture": "mimo_v2_nextn", "storage": "embedded",
                             "num_layers": 3, "file": "model-mtp.safetensors"],
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("conversion_manifest.json"))
        // Actual BPE implementation, finite vocab within the tiny model's128 IDs.
        let vocab = ["<unk>":0,"<|im_end|>":1,"<|image_pad|>":2,"<|video_pad|>":3,"<|vision_start|>":4,"<|vision_end|>":5,"<|audio_pad|>":6,"<|mimo_audio_start|>":7,"<|mimo_audio_end|>":8,"<|mimo_video_start|>":9,"<|mimo_video_end|>":10,"<think>":11,"</think>":12,"x":13,"<|im_start|>":14,"<stop>":15]
        var completeVocab = vocab
        for id in 16..<128 { completeVocab["token" + String(id)] = id }
        let added: [[String: Any]] = vocab.filter { $0.key != "x" }.map { token, id in
            ["id": id, "content": token, "single_word": false, "lstrip": false,
             "rstrip": false, "normalized": false, "special": true]
        }
        let tokenizer: [String: Any] = ["version": "1.0", "truncation": NSNull(), "padding": NSNull(),
            "added_tokens": added, "normalizer": NSNull(), "pre_tokenizer": ["type": "Whitespace"],
            "post_processor": NSNull(), "decoder": ["type": "ByteLevel"],
            "model": ["type": "BPE", "vocab": completeVocab, "merges": [], "unk_token": "<unk>",
                      "byte_fallback": false, "fuse_unk": false]]
        try JSONSerialization.data(withJSONObject: tokenizer, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("tokenizer.json"))
        try JSONSerialization.data(withJSONObject: ["tokenizer_class": "PreTrainedTokenizerFast",
            "eos_token": "<|im_end|>", "unk_token": "<unk>", "chat_template": literal])
            .write(to: root.appendingPathComponent("tokenizer_config.json"))
        try Data(literal.utf8).write(to: root.appendingPathComponent("chat_template.jinja"))
        try JSONSerialization.data(withJSONObject: ["eos_token_id": [1, 15]])
            .write(to: root.appendingPathComponent("generation_config.json"))
        return root
    }

    private func lane() throws {
        try MiMoTestPrerequisites.requireOptIn("MIMO_V26_SERIAL_NATIVE_TESTS")
        guard ProcessInfo.processInfo.environment["MIMO_V26_MANAGED_MEDIA_FAULT_CASE"] == allowedFault else {
            throw XCTSkip("Retained-fault selectors run alone in their own process")
        }
    }

    private func loaded(media: Bool = true, mediaPolicy: MiMoV26ServingLoad.DecodedMediaPolicy? = nil) async throws -> Loaded {
        try lane()
        let root = try fixture()
        let load = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: root, decodedMediaPolicy: media ? try mediaPolicy ?? policy() : nil))
        let registry = MiMoV26NativeLoadRegistry()
        registries.append(registry)
        // Preserve real allocator/OS observations and normal activation/OS/KV
        // reserves. No zero-usage admission oracle or lower floor is used here.
        let budget = GlobalKVCacheBudget(configReserveBytes: 4 << 30)
        try load.claim(budget: budget, lifecycle: registry.openLifecycle(), registry: registry)
        let container = try await load.load()
        let transaction = try XCTUnwrap(load.transaction)
        return .init(root: root, load: load, transaction: transaction, registry: registry,
            budget: budget, container: container,
            tokenizer: await container.tokenizerHandle(modelType: "mimo_v2", directory: root),
            sizing: await container.sizing(modelPath: root, defaultMaxTokens: 32))
    }

    private func prepare(_ value: Loaded, mode: MTPMode,
                         environment: [String: String]? = nil) async throws -> (SpecDecPreparation, EngineV2ServingPreparation) {
        let environment = environment ?? self.environment
        let intent = try MiMoV26ServingLoad.preparation(mode: mode, externalPath: nil, environment: environment)
        let prepared = try await EngineV2SlotFactory.prepareProductionModel(modelId: "managed-mimo-fixture",
            isVLM: false, modelDirectory: value.root, container: value.container, specDecPreparation: intent)
        return (intent, prepared)
    }

    private func build(_ value: Loaded, intent: SpecDecPreparation, prepared: EngineV2ServingPreparation,
                       backend: String = "contiguous", budget: GlobalKVCacheBudget? = nil,
                       environment: [String: String]? = nil,
                       emit: (@Sendable (TelemetryEvent) -> Void)? = nil) async throws -> ProviderEngineBundle {
        try await EngineV2SlotFactory.makeProductionBundle(modelId: "managed-mimo-fixture", modelType: "mimo_v2",
            isVLM: false, modelDirectory: value.root, container: value.container, tokenizer: value.tokenizer,
            sizing: value.sizing, kvBytesCapacity: 2 << 30, maxConcurrentRequests: 2,
            kvBudget: budget ?? value.budget, kvBackendConfig: backend,
            specDecPreparation: intent, preparedModel: prepared, environment: environment ?? self.environment,
            startServingTelemetry: false, emitTelemetry: emit ?? { _ in })
    }

    private func retire(_ value: Loaded) async throws -> MiMoV26NativeRetirementReceipt {
        let result = await value.load.finishFailureAfterUnwind()
        guard case .retired(let receipt) = result else {
            // Unexpected real failed work remains reachable until this test
            // process exits; never turn an unknown outcome into a passed cell.
            if value.registry.hasRetainedFault { _ = Unmanaged.passRetained(value.registry) }
            XCTFail("actual transaction did not retire: \(result)")
            throw FixtureError.unexpectedRetirement
        }
        return receipt
    }

    private func engine(_ bundle: ProviderEngineBundle) async throws -> EngineV2 {
        let value = await bundle.bridge.ownedEngine
        return try XCTUnwrap(value as? EngineV2)
    }

    private func policy(maximumBytes: UInt64 = 128 << 20, maximumVideoFrames: Int = 4,
                        maximumInputElements: Int = 100000, pixelWorkingBytes: Int = 1 << 20) throws -> MiMoV26ServingLoad.DecodedMediaPolicy {
        let limits = MiMoV26MultimodalLimits(maximumMedia: 4, maximumVideoFrames: maximumVideoFrames,
            maximumPromptTokens: 2000, maximumMetadataBytes: 65536,
            maximumMetadataNodes: 10000, maximumMetadataDepth: 32,
            pixels: .init(maximumInputElements: maximumInputElements, maximumOutputElements: 100000, maximumWorkingBytes: pixelWorkingBytes),
            vision: .init(maximumPatches: 256, maximumAttentionScoreElements: 131072),
            audio: .init(maximumClips: 1, maximumChannels: 2, maximumSampleRate: 48000,
                maximumInputSamples: 100000, maximumResampledSamples: 100000,
                maximumResampleCoefficients: 100000, maximumMelFrames: 10000, maximumSegments: 16,
                maximumPaddedMelFrames: 100000, maximumWorkingElements: 1000000,
                frontendFrameBlockSize: 8, rvqTileFrames: 8),
            audioPatch: .init(maximumClips: 1, maximumFrames: 10000,
                maximumPatches: 4096, maximumWorkingElements: 1000000))
        return try .init(limits: limits, maximumReservationBytes: maximumBytes,
            additionalSystemReserveBytes: 4 << 30)
    }

    private func published(mtp: Bool = false, media: Bool = true,
                           mediaPolicy: MiMoV26ServingLoad.DecodedMediaPolicy? = nil) async throws
        -> (Loaded, ProviderEngineBundle, EngineV2) {
        let value = try await loaded(media: media, mediaPolicy: mediaPolicy)
        let (intent, prepared) = try await prepare(value, mode: mtp ? .on : .off)
        let bundle = try await build(value, intent: intent, prepared: prepared)
        _ = try await value.load.sealConstructionForPublication()
        try value.load.commitPublication {}
        return (value, bundle, try await engine(bundle))
    }

    private func acquisition(_ value: Loaded, _ bundle: ProviderEngineBundle)
        -> (MultiModelBatchSchedulerEngine.AcquiredModel, NativeLocalConsumerLease) {
        let lease = NativeLocalConsumerLease()
        let token = OneShotRelease(release: { _ in }, modelId: "managed-mimo-fixture", nativeConsumerLease: lease)
        return (.init(tokenizer: value.tokenizer, releaseToken: token, modelType: "mimo_v2",
            container: value.container.autoregressive, isVLM: false, engineV2Bridge: bundle.bridge), lease)
    }

    private func drain(_ value: Loaded, _ bundle: ProviderEngineBundle, _ actual: EngineV2,
                       lease: NativeLocalConsumerLease? = nil) async throws {
        let contract = try XCTUnwrap(actual.nativeShutdownExecutionContractID)
        do {
            _ = try await bundle.bridge.shutdownNativeConstruction(expectedEngine: actual, executionContractID: contract)
        } catch MiMoV26NativeBridgeShutdownError.pendingConsumers {
            let snapshot = await bundle.bridge.nativeRetirementTaskSnapshot()
            let receipt = try XCTUnwrap(snapshot.sdkQuiescence)
            XCTAssertEqual(receipt.engineID, actual.nativeShutdownEngineID)
            XCTAssertEqual(receipt.executionContractID, contract)
            for task in snapshot.tasks { await task.value }
        }
        if let lease { await lease.joinFromOutside() }
        let receipt = try await retire(value)
        XCTAssertEqual(receipt.engine?.engineID, actual.nativeShutdownEngineID)
        XCTAssertEqual(value.transaction.managedMediaReservationCountForTesting, 0)
    }

    private func application(_ value: Loaded, _ bundle: ProviderEngineBundle, _ owners: Owners) -> LocalInferenceApplication {
        makeLocalInferenceApplication(config:.init(host:"127.0.0.1",port:0,authToken:"synthetic-media-token"),
            defaultMaxTokens:3,acquire:{ _ in
                let lease = NativeLocalConsumerLease(); owners.add(lease)
                return .init(tokenizer:value.tokenizer,
                    releaseToken:.init(release:{ _ in },modelId:"fixture",nativeConsumerLease:lease),
                    modelType:"mimo_v2",container:value.container.autoregressive,isVLM:false,engineV2Bridge:bundle.bridge)
            },tokenizerProvider:{ _ in .init(tokenizer:value.tokenizer,modelType:"mimo_v2") },
            availableModels:{ ["fixture"] },mtpSlots:{ [] })
    }
    private func body(responses: Bool, stream: Bool, uri: String? = nil, choice: String = "auto") throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:MiMoConsumerFixture.httpBody(
            #""enable_thinking":false"#,choice:"\"" + choice + "\"",responses:responses,streaming:stream)) as? [String:Any])
        if responses {
            object["input"] = [["role":"user","content":[
                ["type":"input_image","image_url":uri ?? png],["type":"input_text","text":String(repeating:"x ",count:16)]
            ]]]
            object["max_output_tokens"] = 3
        } else {
            object["messages"] = [["role":"user","content":[
                ["type":"image_url","image_url":["url":uri ?? png]],["type":"text","text":String(repeating:"x ",count:16)]
            ]]]
            object["max_tokens"] = 3
        }
        return try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])
    }

    func testAuthenticatedChatResponsesActuallyRouteEncodedImageThroughNativeBridge() async throws {
        let (value,bundle,actual) = try await published(mtp:true)
        let owners = Owners(), app = application(value,bundle,owners)
        let epoch = value.transaction.snapshot().constructionEpoch
        var prepared: [(responses: Bool, data: Data)] = []
        for responses in [false,true] {
            for stream in [false,true] {
                prepared.append((responses, try body(responses:responses,stream:stream)))
            }
        }
        let requests = prepared // immutable Sendable bytes; do not capture XCTestCase
        try await app.test(.router) { client in
            for request in requests {
                try await client.execute(uri:request.responses ? "/v1/responses" : "/v1/chat/completions",
                    method:.post,headers:[.contentType:"application/json",.authorization:"Bearer synthetic-media-token"],
                    body:ByteBuffer(bytes:request.data)) { result in
                    XCTAssertEqual(result.status,.ok)
                    let text = String(buffer:result.body)
                    XCTAssertFalse(text.contains("data:image"))
                    XCTAssertFalse(text.contains("PRIVATE_OFF_THOUGHT"))
                    XCTAssertFalse(text.contains("response.failed"))
                }
            }
        }
        XCTAssertEqual(owners.acquisitions,4)
        XCTAssertEqual(value.transaction.snapshot().constructionEpoch,epoch)
        XCTAssertEqual(actual.mtpMetricsSnapshot()?.draftedTokens,0,"all four actual media rows are target-only")
        try await drain(value,bundle,actual)
        for lease in owners.all { await lease.joinFromOutside() }
    }

    func testNativeMediaReleasePNGJPEGAndMP4GenerateThroughAuthenticatedRoutes() async throws {
        // 900 source frames previously reserved > 84 MiB of raster scratch.
        // The configured 230 GiB pixel ceiling was also charged as use even
        // for a tiny image. Keep that ceiling and normal KV/OS floors, while
        // the actual request's native graph and 20 sampled RGB frames fit 64 MiB.
        let mediaPolicy = try policy(maximumBytes: 64 << 20, maximumVideoFrames: 32,
            maximumInputElements: 1_000_000, pixelWorkingBytes: 230 << 30)
        let (value, bundle, actual) = try await published(mtp: true, mediaPolicy: mediaPolicy)
        let owners = Owners(), app = application(value, bundle, owners)
        let png = "data:image/png;base64," + (try MiMoEncodedMediaFixtures.image(jpeg: false)).base64EncodedString()
        let jpeg = "data:image/jpeg;base64," + (try MiMoEncodedMediaFixtures.image(jpeg: true)).base64EncodedString()
        let mp4 = "data:video/mp4;base64," + (try await MiMoEncodedMediaFixtures.video(frames: 900, fps: 90)).base64EncodedString()
        var requests: [(path: String, body: Data)] = []
        for image in [png, jpeg] {
            for responses in [false, true] {
                requests.append((responses ? "/v1/responses" : "/v1/chat/completions",
                    try body(responses: responses, stream: false, uri: image)))
            }
        }
        // OpenRouter's documented video_url object, plus an image in the same
        // request, exercises combined reservation and real visual inference.
        var mixed = try XCTUnwrap(JSONSerialization.jsonObject(with: body(responses:false,stream:false)) as? [String:Any])
        mixed["messages"] = [["role":"user","content":[
            ["type":"image_url","image_url":["url":jpeg]],
            ["type":"video_url","video_url":["url":mp4]],
            ["type":"text","text":String(repeating:"x ",count:16)],
        ]]]
        requests.append(("/v1/chat/completions", try JSONSerialization.data(withJSONObject:mixed)))
        let immutableRequests = requests
        try await app.test(.router) { client in
            for (index, request) in immutableRequests.enumerated() {
                try await client.execute(uri:request.path, method:.post,
                    headers:[.contentType:"application/json",.authorization:"Bearer synthetic-media-token"],
                    body:ByteBuffer(bytes:request.body)) { result in
                    XCTAssertEqual(result.status,.ok,"media request \(index): \(request.path)")
                    let response = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(result.body.readableBytesView)) as? [String:Any])
                    XCTAssertNil(response["error"])
                    let usage = try XCTUnwrap(response["usage"] as? [String:Any])
                    if request.path == "/v1/responses" {
                        XCTAssertEqual(response["status"] as? String,"completed")
                        XCTAssertGreaterThan(try XCTUnwrap(usage["output_tokens"] as? Int),0)
                    } else {
                        XCTAssertGreaterThan(try XCTUnwrap(usage["completion_tokens"] as? Int),0)
                        XCTAssertFalse(try XCTUnwrap(response["choices"] as? [Any]).isEmpty)
                    }
                }
                for lease in owners.all { await lease.joinFromOutside() }
            }
        }
        XCTAssertEqual(owners.acquisitions,5)
        XCTAssertEqual(actual.mtpMetricsSnapshot()?.draftedTokens,0,"media remains target-only")
        for lease in owners.all { await lease.joinFromOutside() }
        XCTAssertEqual(value.transaction.managedMediaReservationCountForTesting,0)
        try await drain(value,bundle,actual)
    }

    func testRealAuthenticatedIngressRefusesRemoteURIsBoundsAndUnsupportedControlsBeforeDecode() async throws {
        let (value,bundle,actual) = try await published()
        let owners = Owners(), app = application(value,bundle,owners)
        let good = try body(responses:false,stream:false)
        let refusedURIs = ["https://example.invalid/private.png","file:///private/not-authorized","data:image/png;base64,AAAA"]
        let refusedBodies = try refusedURIs.map { try body(responses:false,stream:false,uri:$0) }
        try await app.test(.router) { client in
            try await client.execute(uri:"/v1/chat/completions",method:.post,
                headers:[.contentType:"application/json",.authorization:"Bearer wrong"],body:ByteBuffer(bytes:good)) {
                XCTAssertEqual($0.status,.unauthorized)
            }
            XCTAssertEqual(owners.acquisitions,0)
            for data in refusedBodies {
                try await client.execute(uri:"/v1/chat/completions",method:.post,
                    headers:[.contentType:"application/json",.authorization:"Bearer synthetic-media-token"],
                    body:ByteBuffer(bytes:data)) { XCTAssertEqual($0.status,.badRequest) }
            }
            let knobs: [[String:Any]] = [["logprobs":true],["top_logprobs":1],["min_p":0.5],
                                         ["enable_thinking":"false"]]
            for knob in knobs {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with:good) as? [String:Any])
                object.merge(knob) { _,new in new }
                let data = try JSONSerialization.data(withJSONObject:object)
                try await client.execute(uri:"/v1/chat/completions",method:.post,
                    headers:[.contentType:"application/json",.authorization:"Bearer synthetic-media-token"],
                    body:ByteBuffer(bytes:data)) { XCTAssertEqual($0.status,.badRequest) }
            }
            let oversized = Data(repeating:32,count:2_097_153)
            let before = owners.acquisitions
            try await client.execute(uri:"/v1/responses",method:.post,
                headers:[.contentType:"application/json",.authorization:"Bearer synthetic-media-token"],
                body:ByteBuffer(bytes:oversized)) { XCTAssertEqual($0.status,.contentTooLarge) }
            XCTAssertEqual(owners.acquisitions,before)
        }
        try await drain(value,bundle,actual)
        for lease in owners.all { await lease.joinFromOutside() }
    }

    func testMediaRichCapsuleAcceptsAbsentFalseZeroNullButRejectsRequestedOrMalformedValues() throws {
        for fragment in ["",#""logprobs":false"#,#""top_logprobs":0"#,#""logprobs":null,"top_logprobs":null"#] {
            let data = MiMoConsumerFixture.body(fragment)
            let remote = ProviderLoop.extractChatTemplateControls(from:data)
            let local = try JSONDecoder().decode(LocalChatRequest.self,from:data)
            XCTAssertEqual(remote.rawMiMoControls,local.templateControls.rawMiMoControls)
            XCTAssertNoThrow(try remote.rawMiMoControls.validateMedia(modelType:"mimo_v2"))
        }
        for fragment in [#""logprobs":true"#,#""logprobs":"false""#,#""logprobs":0"#,
                         #""top_logprobs":1"#,#""top_logprobs":false"#,#""top_logprobs":"0""#] {
            let evidence = ProviderLoop.extractChatTemplateControls(from:MiMoConsumerFixture.body(fragment)).rawMiMoControls
            XCTAssertTrue(evidence.unsupportedMediaRichControls)
            XCTAssertThrowsError(try evidence.validateMedia(modelType:"mimo_v2"))
            XCTAssertNoThrow(try evidence.validate(modelType:"mimo_v2"),"text controls unchanged")
            XCTAssertNoThrow(try evidence.validateMedia(modelType:"llama"))
        }
        for (extra,bad) in [(#""include":[],"text":{"format":{"type":"text"}}"#,false),
                            (#""include":["message.output_text.logprobs"]"#,true),
                            (#""text":{"format":{"type":"json_object"}}"#,true)] {
            let data = Data(("{\"model\":\"fixture\",\"input\":\"x\"," + extra + "}").utf8)
            let response = try JSONDecoder().decode(LocalResponseRequest.self,from:data)
            XCTAssertEqual(response.templateControls.rawMiMoControls.unsupportedMediaRichControls,bad)
        }
    }

    func testRealNativeRouterKeepsToolArgumentTagsOpaqueWithThinkingDisabled() throws {
        let value = "literal &amp; null </function> </tool_call> <think>ARGUMENT_NOT_THOUGHT</think>"
        let frame = "<tool_call><function=echo><parameter=text>" + value + "</parameter></function></tool_call>"
        for choice in [#""auto""#,#""none""#,#""required""#,#"{"type":"function","function":{"name":"echo"}}"#] {
            let request = try ProviderLoop.decodeOpenAIRequest(MiMoConsumerFixture.body(#""enable_thinking":false"#,choice:choice))
            let prepared = try ToolChoicePromptPolicy.prepare(request,modelType:"mimo_v2")
            let handler = try XCTUnwrap(ToolStreamPreparation.makeHandler(request:request,prepared:prepared,modelType:"mimo_v2"))
            var router = NativeToolStreamRouter(handler:handler,requiresToolCall:prepared.requiresToolCall,
                nativePrefix:"",preserveInnerReasoningSpans:true,
                nativeMiMoChannels:true,nativeMiMoThinkingEnabled:false,
                nativeMiMoRequiresConstraint:prepared.mode.requiresInferenceConstraint)
            var events: [MLXServerGenerationEvent] = []
            for scalar in frame.unicodeScalars { events += try router.process(String(scalar)) }
            events += try router.finishText()
            XCTAssertTrue(events.isEmpty,"argument bytes must never become visible content/reasoning")
            let calls = handler.finish()
            XCTAssertEqual(calls.first?.function.arguments["text"],.string(value))
            XCTAssertEqual(handler.parseFailureCount,0)
            if prepared.mode == .none {
                XCTAssertThrowsError(try ToolConstraintValidation.validate(calls,prepared:prepared))
            } else {
                XCTAssertNoThrow(try ToolConstraintValidation.validate(calls,prepared:prepared))
            }
        }
        // Scripted generated bytes, REAL parser/router/validator; not a native
        // model-generation quality pass. HTTP tests above use the actual model.
    }

    func testActualNormalizedJinjaNullHistoryAndClockSnapshotRenderParity() throws {
        let data = Data(#"""
        {"model":"fixture","enable_thinking":false,"messages":[
          {"role":"assistant","content":null,"reasoning_content":"prior",
           "tool_calls":[{"id":"b","type":"function","function":{"name":"echo","arguments":"{\"text\":\"null\",\"value\":null}"}},
                         {"id":"a","type":"function","function":{"name":"echo","arguments":"{\"text\":\"&amp;\"}"}}]},
          {"role":"tool","tool_call_id":"a","content":"second"},
          {"role":"tool","tool_call_id":"b","content":"first"},
          {"role":"user","content":"continue"}],
         "tools":[{"type":"function","function":{"name":"echo","parameters":{"type":"object",
             "properties":{"text":{"type":"string","default":null}}}}}]}
        """#.utf8)
        let request = try ProviderLoop.decodeOpenAIRequest(data)
        let controls = ProviderLoop.extractChatTemplateControls(from:data)
            .withPromptDate(try XCTUnwrap(PromptRenderDate("2001-02-03")))
        let normalized = try ProviderPromptContractPipeline.normalizedInput(
            prepared:ToolChoicePromptPolicy.prepare(request,modelType:"mimo_v2"),
            request:request,modelType:"mimo_v2",templateControls:controls)
        XCTAssertEqual(normalized.messages[1]["tool_call_id"] as? String,"b")
        XCTAssertEqual(normalized.messages[2]["tool_call_id"] as? String,"a")
        var nodes = 0, bytes = 0
        try MiMoV26MediaMetadata.validate(normalized.messages,limits:policy().limits,nodes:&nodes,bytes:&bytes)
        let snapshot = try MiMoV26MediaRequestClock(utcGregorianDay:controls.promptDate!.value)
        let original = try XCTUnwrap(normalized.additionalContext?["_darkbloom_request_clock"] as? Jinja.Value)
        let source = "{{ strftime_now('%Y-%m-%d') }}|{{ messages|tojson }}|{{ tools|tojson }}"
        func render(_ clock: Jinja.Value) throws -> String {
            try Template(normalizeSwiftJinjaTemplate(source),with:.init(lstripBlocks:true,trimBlocks:true)).render(["_darkbloom_request_clock":clock,"messages":try Jinja.Value(any:normalized.messages),
                "tools":try Jinja.Value(any:normalized.tools ?? [])])
        }
        XCTAssertEqual(Data(try render(original).utf8),Data(try render(snapshot.templateValue).utf8))
        XCTAssertTrue(try render(snapshot.templateValue).contains("2001-02-03"))
        let forgedValues: [Any] = [Jinja.Value.function { _,_,_ in .string("FORGED") },
            ["nested":Jinja.Value.function { _,_,_ in .null }],
            ["_darkbloom_request_clock":Jinja.Value.function { _,_,_ in .string("FORGED") }]]
        for forged in forgedValues {
            nodes = 0; bytes = 0
            XCTAssertThrowsError(try MiMoV26MediaMetadata.validate(forged,limits:policy().limits,nodes:&nodes,bytes:&bytes))
        }
        XCTAssertThrowsError(try MiMoV26MediaRequestClock(utcGregorianDay:"2026-02-30"))
        XCTAssertThrowsError(try MiMoV26MediaRequestClock(utcGregorianDay:"arbitrary callable"))
        for call in ["{{ strftime_now() }}","{{ strftime_now('%Y-%m-%d', extra=1) }}",
                     "{{ strftime_now('%Y-%m-%d', 'extra') }}"] {
            func outcome(_ clock: Jinja.Value) -> Result<String,Error> {
                Result { try Template(normalizeSwiftJinjaTemplate(call),with:.init(lstripBlocks:true,trimBlocks:true)).render(["_darkbloom_request_clock":clock]) }
            }
            switch (outcome(original),outcome(snapshot.templateValue)) {
            case (.success,.success): break // ambient clock values intentionally not compared
            case (.failure(let a),.failure(let b)): XCTAssertEqual(String(reflecting:type(of:a)),String(reflecting:type(of:b)))
            default: XCTFail("clock arity/fallback behavior diverged")
            }
        }
        // Nonliteral fallback uses the existing ambient clock; no byte-parity
        // assertion is made for calls evaluated at different instants.
    }

    func testActualNativeFeatureRetirementKeepsEncodedChargeThroughHeldForwardingTaskTail() async throws {
        let (value,bundle,actual) = try await published()
        let (acquired,lease) = acquisition(value,bundle)
        let payload = NativeLocalAcquisitionPayload(consume acquired)
        var scheduler = MultiModelBatchSchedulerEngine(acquire:{ _ in
            try XCTUnwrap(payload.take())
        },tokenizerProvider:{ _ in .init(tokenizer:value.tokenizer,modelType:"mimo_v2") },
            availableModels:{ ["fixture"] },defaultMaxTokens:3,
            templateControls:.init(enableThinking:false))
        let entered = expectation(description:"actual router received real terminal usage")
        let gate = TailGate(entered)
        scheduler._testNativeForwardingHold = { point in
            if case .receivedEvent(.info) = point { await gate.hold() }
        }
        let request = try ProviderLoop.decodeOpenAIRequest(body(responses:false,stream:true))
        let stream = try await scheduler.streamChatCompletion(request:request)
        let collector = Task { for try await _ in stream {} }
        await fulfillment(of:[entered],timeout:30)
        // The bridge proof precedes any dependent task join, and the held
        // consumer still owns its real encoded buffers despite retired rows.
        let proof = await actual.shutdownReportingNativeCompletion()
        guard case .quiescent = proof else { await gate.open(); return XCTFail("native work did not quiesce") }
        XCTAssertGreaterThan(value.transaction.managedMediaChargedBytesForTesting,0)
        XCTAssertGreaterThan(value.transaction.managedMediaReservationCountForTesting,0)
        await gate.open()
        try await collector.value
        await lease.joinFromOutside()
        XCTAssertEqual(value.transaction.managedMediaReservationCountForTesting,0)
        try await drain(value,bundle,actual)
    }

    func testActualMemoryBackedVideoIndicesAndAuthenticatedNativeRoute() async throws {
        let (value,bundle,actual) = try await published()
        let uri = "data:video/mp4;base64," + mp4Base64
        let ingested = try await MediaIngest.decodeVideo(uri)
        guard case .memoryBacked(let owner) = ingested.video else { return XCTFail("plaintext/url video path") }
        let limits = MiMoV26EncodedVisualDecoder.Limits(maximumPixels:10000,
            maximumWorkingBytes:16 << 20,maximumSourceFrames:10000,maximumSampledFrames:4)
        let planned = try await MiMoV26EncodedVisualDecoder.inspectVideo(owner,
            sampling:.init(fps:1,minimumFrames:8,maximumFrames:3600),limits:limits)
        XCTAssertEqual(planned.sourceFrameCount,3)
        XCTAssertEqual(planned.sampledIndices,[0,2])
        XCTAssertEqual(planned.timestamps,[0,Float(2)/Float(planned.averageFPS)])
        XCTAssertFalse(planned.hasAudioTrack)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:body(responses:false,stream:false)) as? [String:Any])
        object["messages"] = [["role":"user","content":[
            ["type":"video_url","video_url":["url":uri]],["type":"text","text":"x x x x x x x x x x"]
        ]]]
        let data = try JSONSerialization.data(withJSONObject:object)
        let owners = Owners()
        try await application(value,bundle,owners).test(.router) { client in
            try await client.execute(uri:"/v1/chat/completions",method:.post,
                headers:[.contentType:"application/json",.authorization:"Bearer synthetic-media-token"],
                body:ByteBuffer(bytes:data)) { XCTAssertEqual($0.status,.ok) }
        }
        XCTAssertEqual(owners.acquisitions,1)
        try await drain(value,bundle,actual)
    }

    func testActualAudioTrackRequiresAudiovisualProfileBeforeNativeFrameWork() async throws {
        try MiMoTestPrerequisites.requireOptIn("MIMO_V26_INGRESS_AUDIO_VIDEO_TESTS")
        // Required future qualification input, not synthesized track flags.
        // Root/audio worker supplies a bounded valid MP4 with actual audio.
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["MIMO_V26_INGRESS_AUDIO_VIDEO_FIXTURE"])
        let data = try MiMoV26ServingLoad.readMetadata(URL(fileURLWithPath:path),limit:1 << 20).bytes
        let owner = try MemoryBackedVideoAsset(videoData:data)
        let limits = MiMoV26EncodedVisualDecoder.Limits(maximumPixels:10000,
            maximumWorkingBytes:16 << 20,maximumSourceFrames:10000,maximumSampledFrames:32)
        let plan = try await MiMoV26EncodedVisualDecoder.inspectVideo(owner,
            sampling:.init(fps:1,minimumFrames:8,maximumFrames:3600),limits:limits)
        XCTAssertTrue(plan.hasAudioTrack)
        do { _ = try await MiMoV26EncodedVisualDecoder.silentVideo(plan,limits:limits); XCTFail("sound was silently dropped") }
        catch { XCTAssertEqual(error as? MiMoV26EncodedVisualDecoder.Failure,.audioTrackRequiresAudiovisualProfile) }
    }

    #if DEBUG
    private func deadlineFixture(mode: PrefillDeadlineMode = .enforce, media: Bool = true) async throws
        -> (Loaded, ProviderEngineBundle, EngineV2) {
        let value = try await loaded(media: media)
        let env = environment.merging([
            PrefillDeadlineMode.environmentKey: mode.rawValue,
            EngineV2Factory.maxPartialPrefillsKey: "1",
        ]) { _, new in new }
        let (intent, prepared) = try await prepare(value, mode: .off, environment: env)
        let bundle = try await build(value, intent: intent, prepared: prepared, environment: env)
        _ = try await value.load.sealConstructionForPublication()
        try value.load.commitPublication {}
        return (value, bundle, try await engine(bundle))
    }

    private func deadlineMedia(_ value: Loaded, _ bundle: ProviderEngineBundle) async throws -> CBv2Request {
        let image = MiMoV26Pixels.DecodedRGB(height: 4, width: 4,
            planarRGB: (0..<48).map { Float(($0 * 17) % 256) })
        let input = MiMoV26MultimodalInput(messages: [.init(role: .user,
            content: [.image(image), .text("x x x x")])], maximumOutputTokens: 3)
        return try await value.transaction.prepareDecodedMedia(input, policy: policy(),
            expectedContainer: XCTUnwrap(value.container.autoregressive),
            expectedBridge: bundle.bridge).request
    }

    func testNativePreparedSealReachesRealAtomicDeadlineRejectionWithoutLosingCharge() async throws {
        let (value, bundle, actual) = try await deadlineFixture()
        let native = try await deadlineMedia(value, bundle)
        let media = try XCTUnwrap(native.multimodal)
        let deadline = FirstContentDeadline(relativeBudgetMilliseconds: 60_000)
        let missing = try await bundle.bridge.firstTokenDeadlineAdmission(deadline: deadline, multimodal: media)
        XCTAssertNil(missing, "unchanged unmeasured-rate policy")
        // Controlled conservative policy boundary, NOT a measured throughput
        // claim. The SDK still projects actual queued tokens and the real clock.
        await bundle.bridge._testSeedIsolatedPrefillEwma(0.001)
        let projected = try await bundle.bridge.firstTokenDeadlineAdmission(deadline: deadline, multimodal: media)
        let admission = try XCTUnwrap(projected)
        XCTAssertEqual(admission.deadline, deadline.instant)
        XCTAssertGreaterThan(try XCTUnwrap(admission.conservativePrefillTokensPerSecond), 0)
        let before = actual.stepCount
        let charged = value.transaction.managedMediaChargedBytesForTesting
        XCTAssertGreaterThan(charged, 0)
        let profile = RequestProfileBuilder()
        do {
            _ = try await bundle.bridge.submitTokenized(promptTokens: native.promptTokens,
                request: .init(model: "managed-mimo-fixture", messages: [], max_tokens: 3),
                requestId: "sealed-atomic-deadline", cacheEnabled: false, multimodal: media,
                firstContentDeadline: deadline, profile: profile)
            XCTFail("ordinary submission bypassed real atomic deadline refusal")
        } catch {
            XCTAssertEqual(error as? PreContentDeadlineFailure, .deadlineUnreachable)
        }
        let wire = profile.wireObject()
        XCTAssertEqual(wire.deadlineDecision?.verdict, .deadlineUnreachable)
        XCTAssertEqual(wire.deadlineDecision?.projection, .bounded)
        XCTAssertEqual(actual.stepCount, before)
        XCTAssertEqual(value.transaction.managedMediaChargedBytesForTesting, charged)
        let pending = await bundle.bridge._testPendingEngineIDCount()
        let mapped = await bundle.bridge._testMappedRequestCount()
        XCTAssertEqual(pending, 0); XCTAssertEqual(mapped, 0)
        actual.discardUnsubmittedNativeMedia(media)
        XCTAssertEqual(value.transaction.managedMediaReservationCountForTesting, 0)
        try await drain(value, bundle, actual)
    }

    func testTypedDeadlineGatePreservesRawTextAndOffPolicyAndRefusesForeignCapability() async throws {
        let (value, bundle, actual) = try await deadlineFixture()
        let native = try await deadlineMedia(value, bundle)
        let media = try XCTUnwrap(native.multimodal)
        let deadline = FirstContentDeadline(relativeBudgetMilliseconds: 60_000)
        await bundle.bridge._testSeedIsolatedPrefillEwma(1)
        let text = try await bundle.bridge.firstTokenDeadlineAdmission(deadline: deadline, multimodal: nil)
        let legacyText = await bundle.bridge.firstTokenDeadlineAdmission(deadline: deadline, isMultimodal: false)
        XCTAssertEqual(text, legacyText)
        let raw = CBv2MultimodalInput(spans: media.spans, attention: .causal) {
            throw MiMoV26MultimodalError.incompatibleOwner
        }
        let rawResult = try await bundle.bridge.firstTokenDeadlineAdmission(deadline: deadline, multimodal: raw)
        XCTAssertNil(rawResult)

        let (offValue, offBundle, offEngine) = try await deadlineFixture(mode: .off)
        await offBundle.bridge._testSeedIsolatedPrefillEwma(1)
        let off = try await offBundle.bridge.firstTokenDeadlineAdmission(deadline: deadline, multimodal: media)
        XCTAssertNil(off, "explicit off policy remains authoritative")
        try await drain(offValue, offBundle, offEngine)

        let (textValue, textBundle, textEngine) = try await deadlineFixture(media: false)
        await textBundle.bridge._testSeedIsolatedPrefillEwma(1)
        let before = textValue.budget.processLedger.snapshot().chargedBytes
        let stream = try await textBundle.bridge.submitTokenized(promptTokens: native.promptTokens,
            request: .init(model: "managed-mimo-fixture", messages: [], max_tokens: 3),
            requestId: "foreign-media-capability", cacheEnabled: false, multimodal: media,
            firstContentDeadline: deadline)
        var errors = 0, chunks = 0
        for await event in stream {
            if case .error = event { errors += 1 }
            if case .chunk = event { chunks += 1 }
        }
        XCTAssertEqual(errors, 1); XCTAssertEqual(chunks, 0)
        XCTAssertEqual(textValue.budget.processLedger.snapshot().chargedBytes, before,
            "capability refusal unwinds the actual bridge's shared KV promise")
        let pending = await textBundle.bridge._testPendingEngineIDCount()
        let mapped = await textBundle.bridge._testMappedRequestCount()
        XCTAssertEqual(pending, 0); XCTAssertEqual(mapped, 0)
        XCTAssertEqual(textEngine.stepCount, 0)
        actual.discardUnsubmittedNativeMedia(media)
        XCTAssertEqual(value.transaction.managedMediaReservationCountForTesting, 0)
        try await drain(textValue, textBundle, textEngine)
        try await drain(value, bundle, actual)
    }
    #endif
}
