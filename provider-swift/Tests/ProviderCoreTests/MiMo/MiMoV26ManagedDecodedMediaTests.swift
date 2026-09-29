import Foundation
import MLX
import MLXVLM
import XCTest
@testable import MLXLMCommon
@_spi(Benchmarking) @testable import ProviderCore

/// Prepared, never executed by this worker. Real local tokenizer/Jinja,
/// strict tiny bundle, actual slot/bridge/native request retirement.
final class MiMoV26ManagedDecodedMediaTests: XCTestCase {
    private final class Gate: @unchecked Sendable {
        let entered: XCTestExpectation
        private let lock = NSLock()
        private var first = true
        private let semaphore = DispatchSemaphore(value: 0)
        init(_ entered: XCTestExpectation) { self.entered = entered }
        func hold() {
            guard lock.withLock({ let result = first; first = false; return result }) else { return }
            entered.fulfill(); semaphore.wait()
        }
        func release() { semaphore.signal() }
    }
    private final class ReleaseWitness: @unchecked Sendable {
        private let lock = NSLock()
        private var modelIDs: [String] = []
        let completed: XCTestExpectation
        init(_ completed: XCTestExpectation) { self.completed = completed }
        func release(_ modelID: String) {
            lock.withLock { modelIDs.append(modelID) }
            completed.fulfill()
        }
        var releasedModelIDs: [String] { lock.withLock { modelIDs } }
    }
    private var releaseWitnesses: [UUID: ReleaseWitness] = [:]
    private var allowedFault: String?
    private enum FixtureError: Error { case nativeLaneRequired, payloadFixtureRequired, unexpectedRetirement, injectedFence }
    private let literal = "<|im_start|>{% for message in messages %}{% if message.content is string %}{{ message.content }}{% else %}{% for item in message.content %}{% if item.type == 'image' %}<|vision_start|><|image_pad|><|vision_end|>{% elif item.type == 'video' %}<|vision_start|><|video_pad|><|vision_end|>{% else %}{{ item.text }}{% endif %}{% endfor %}{% endif %}{% endfor %}<think>{% if enable_thinking is false %}</think>{% endif %}"
    private let environment = ["DARKBLOOM_PREFIX_CACHE":"0","DARKBLOOM_PREFIX_CACHE_MEMORY":"0"]
    private var registries: [MiMoV26NativeLoadRegistry] = []
    override func tearDown() {
        for registry in registries where !registry.retainedTransactionIDs.isEmpty { _ = Unmanaged.passRetained(registry) }
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
        let added: [[String: Any]] = vocab.filter { $0.key != "x" }.map { token, id in
            ["id": id, "content": token, "single_word": false, "lstrip": false,
             "rstrip": false, "normalized": false, "special": true]
        }
        let tokenizer: [String: Any] = ["version": "1.0", "truncation": NSNull(), "padding": NSNull(),
            "added_tokens": added, "normalizer": NSNull(), "pre_tokenizer": ["type": "Whitespace"],
            "post_processor": NSNull(), "decoder": ["type": "ByteLevel"],
            "model": ["type": "BPE", "vocab": vocab, "merges": [], "unk_token": "<unk>",
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
        guard ProcessInfo.processInfo.environment["MIMO_V26_SERIAL_NATIVE_TESTS"] == "1",
              ProcessInfo.processInfo.environment["MIMO_V26_MANAGED_MEDIA_FAULT_CASE"] == allowedFault else {
            throw FixtureError.nativeLaneRequired
        }
    }

    private func loaded(media: Bool = true) async throws -> Loaded {
        try lane()
        let root = try fixture()
        let load = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: root, decodedMediaPolicy: media ? try policy() : nil))
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
            sizing: value.sizing, kvBytesCapacity: 64 << 20, maxConcurrentRequests: 2,
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

    private func policy(maximumBytes: UInt64 = 128 << 20) throws -> MiMoV26ServingLoad.DecodedMediaPolicy {
        let limits = MiMoV26MultimodalLimits(maximumMedia: 4, maximumVideoFrames: 4,
            maximumPromptTokens: 120, maximumMetadataBytes: 65536,
            maximumMetadataNodes: 10000, maximumMetadataDepth: 32,
            pixels: .init(maximumInputElements: 10000, maximumOutputElements: 10000, maximumWorkingBytes: 1 << 20),
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
    private func input(video: Bool = false) -> MiMoV26MultimodalInput {
        let frame = MiMoV26Pixels.DecodedRGB(height: 4, width: 4,
            planarRGB: (0..<48).map { Float(($0 * 17) % 256) })
        let content: MiMoV26MultimodalContent = video
            ? .silentVideo(.init(frames: [frame,frame], timestamps: [0,1])) : .image(frame)
        return .init(messages: [.init(role: .user, content: [content,.text(String(repeating:"x ",count:16))])],
            additionalContext: ["enable_thinking":false], maximumOutputTokens: 3)
    }
    private func published(mtp: Bool = false, media: Bool = true) async throws
        -> (Loaded, ProviderEngineBundle, EngineV2) {
        let value = try await loaded(media: media)
        let (intent, prepared) = try await prepare(value, mode: mtp ? .on : .off)
        let bundle = try await build(value, intent: intent, prepared: prepared)
        _ = try await value.load.sealConstructionForPublication()
        try value.load.commitPublication {}
        return (value, bundle, try await engine(bundle))
    }
    private func acquisition(_ value: Loaded, _ bundle: ProviderEngineBundle)
        -> (MultiModelBatchSchedulerEngine.AcquiredModel, NativeLocalConsumerLease) {
        let lease = NativeLocalConsumerLease()
        let witness = ReleaseWitness(expectation(description: "actual acquired release callback"))
        releaseWitnesses[lease.id] = witness
        let token = OneShotRelease(release: { witness.release($0) },
            modelId: "managed-mimo-fixture", nativeConsumerLease: lease)
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

    func testRealManagedImageAndSilentVideoWithTextMTPShareOneEngine() async throws {
        let (value,bundle,actual) = try await published(mtp: true)
        let epoch = value.transaction.snapshot().constructionEpoch
        let identity = actual.nativeShutdownEngineID
        for video in [false,true] {
            let (acquired,lease) = acquisition(value,bundle)
            let events = try await value.load.submitDecodedMedia(input(video: video),
                request: .init(model:"managed-mimo-fixture",messages:[],temperature:0,max_tokens:3), acquired: acquired)
            var infos = 0
            for await event in events {
                switch event {
                case .error(let message): XCTFail(message)
                case .terminal: XCTFail("unexpected engine failure")
                case .info(let prompt,let count,_,_):
                    XCTAssertGreaterThan(prompt,8, "the real tiny target's SWA ring must wrap")
                    XCTAssertGreaterThanOrEqual(count,0)
                    XCTAssertLessThanOrEqual(count,3); infos += 1
                default: break
                }
            }
            XCTAssertEqual(infos,1)
            await lease.joinFromOutside()
            let witness = try XCTUnwrap(releaseWitnesses[lease.id])
            await fulfillment(of: [witness.completed], timeout: 5)
            XCTAssertEqual(witness.releasedModelIDs, ["managed-mimo-fixture"])
            XCTAssertEqual(actual.mtpMetricsSnapshot()?.draftedTokens,0,
                "decoded media remains native target-only despite the installed text assistant")
            XCTAssertEqual(value.transaction.snapshot().constructionEpoch,epoch)
            let current = await bundle.bridge.ownedEngine
            XCTAssertTrue(current === actual)
        }
        XCTAssertEqual(actual.nativeShutdownEngineID,identity)
        let beforeText = try XCTUnwrap(actual.mtpMetricsSnapshot())
        print("MiMo media-to-text before seeds=\(beforeText.seedSteps) rounds=\(beforeText.rounds) depths=\(beforeText.depthSelections) reasons=\(beforeText.controllerFallbacks)")
        // Prefill + adaptive depth-zero calibration consume two output slots.
        // A three-token probe cannot leave room for a draft plus verification.
        // Keep the positive-drafting gate, with a bounded eligible text tail.
        let text = try actual.submitWithNativeRetirement(.init(id:.init(99),promptTokens:[14,13,11,12],
            sampling:.init(temperature:0),maxTokens:8))
        for await _ in text.events {}
        await text.retirement.wait()
        let afterText = try XCTUnwrap(actual.mtpMetricsSnapshot())
        print("MiMo media-to-text after seeds=\(afterText.seedSteps) rounds=\(afterText.rounds) drafts=\(afterText.draftedTokens) depths=\(afterText.depthSelections) reasons=\(afterText.controllerFallbacks)")
        XCTAssertGreaterThan(afterText.draftedTokens,0)
        try await drain(value,bundle,actual)
    }

    func testSealRefusesClosureSpanPromptMutationReplayAndForeignEngine() async throws {
        let (value,bundle,actual) = try await published()
        let (foreign,foreignBundle,foreignEngine) = try await published(media:false)
        let prepared = try await value.transaction.prepareDecodedMedia(input(),policy:policy(),
            expectedContainer:XCTUnwrap(value.container.autoregressive),expectedBridge:bundle.bridge)
        let token = try XCTUnwrap(prepared.request.multimodal?.nativeMediaToken)
        XCTAssertGreaterThan(value.transaction.managedMediaReservationCountForTesting,0)
        XCTAssertThrowsError(try prepared.request.multimodal!.embeddings())
        var changed = prepared.request
        changed.multimodal!.embeddings = { [] }
        XCTAssertNil(changed.multimodal?.nativeMediaToken)
        XCTAssertThrowsError(try actual.submit(changed))
        changed = prepared.request; changed.multimodal!.spans = []
        XCTAssertNil(changed.multimodal?.nativeMediaToken)
        XCTAssertThrowsError(try actual.submit(changed))
        changed = prepared.request; changed.promptTokens.append(13)
        XCTAssertThrowsError(try actual.submit(changed))
        changed = prepared.request; changed.maxTokens = 0
        XCTAssertThrowsError(try actual.submit(changed), "mutated budget must not take the immediate-success branch")
        XCTAssertThrowsError(try foreignEngine.submit(prepared.request))
        XCTAssertTrue(prepared.request.multimodal?.nativeMediaToken === token)
        let submitted = try actual.submitWithNativeRetirement(prepared.request)
        XCTAssertThrowsError(try actual.submit(prepared.request))
        for await _ in submitted.events {}
        await submitted.retirement.wait()
        XCTAssertEqual(value.transaction.managedMediaReservationCountForTesting,0)
        XCTAssertThrowsError(try actual.submit(prepared.request))
        try await drain(value,bundle,actual)
        try await drain(foreign,foreignBundle,foreignEngine)
    }

    func testPreparationBudgetRefusalAndOriginalTextF1RefusalDoNoNativeWork() async throws {
        let (value,bundle,actual) = try await published()
        let before = value.budget.processLedger.snapshot().chargedBytes
        do {
            _ = try await value.transaction.prepareDecodedMedia(input(),policy:policy(maximumBytes:1),
                expectedContainer:XCTUnwrap(value.container.autoregressive),expectedBridge:bundle.bridge)
            XCTFail("unfunded preparation accepted")
        } catch {}
        XCTAssertEqual(value.transaction.managedMediaReservationCountForTesting,0)
        XCTAssertEqual(value.budget.processLedger.snapshot().chargedBytes,before)
        let (text,textBundle,textEngine) = try await published(media:false)
        do {
            _ = try await text.transaction.prepareDecodedMedia(input(),policy:policy(),
                expectedContainer:XCTUnwrap(text.container.autoregressive),expectedBridge:textBundle.bridge)
            XCTFail("text-only issued profile admitted media")
        } catch {}
        XCTAssertEqual(text.transaction.managedMediaReservationCountForTesting,0)
        try await drain(value,bundle,actual)
        try await drain(text,textBundle,textEngine)
    }

    func testCancellationAtRealPreparationFenceRetainsChargeUntilReturn() async throws {
        let (value,bundle,actual) = try await published()
        let tracking = try XCTUnwrap(actual.loopForTesting.nativeShutdownState)
        let gate = Gate(expectation(description:"real preparation reached its required fence"))
        defer { gate.release() }
        actual.loopForTesting.onEngineQueueSync { tracking.beforeFenceForTesting = { _ in gate.hold() } }
        let (acquired,lease) = acquisition(value,bundle)
        let before = value.budget.processLedger.snapshot().chargedBytes
        let mediaInput = input()
        let task = Task {
            try await value.load.submitDecodedMedia(mediaInput,
                request:.init(model:"managed-mimo-fixture",messages:[],max_tokens:3),acquired:acquired)
        }
        await fulfillment(of:[gate.entered],timeout:10)
        XCTAssertGreaterThan(value.transaction.managedMediaReservationCountForTesting,0)
        XCTAssertEqual(value.budget.processLedger.snapshot().chargedBytes - before,
            value.transaction.managedMediaChargedBytesForTesting,
            "preparation owns only its feature/work charge, not another target KV reservation")
        XCTAssertGreaterThan(value.transaction.snapshot().activeOperations,0)
        do {
            _ = try await value.load.submitDecodedMedia(mediaInput,
                request:.init(model:"managed-mimo-fixture",messages:[],max_tokens:3),acquired:acquired)
            XCTFail("duplicate acquisition started another native preparation")
        } catch {}
        XCTAssertEqual(lease.snapshot().phase,.active, "duplicate refusal must preserve the first pipeline")
        let duplicateGate = NativeLocalTaskStartGate()
        let cancelledDuplicate = Task {
            await duplicateGate.wait()
            return try await value.load.submitDecodedMedia(mediaInput,
                request:.init(model:"managed-mimo-fixture",messages:[],max_tokens:3),acquired:acquired)
        }
        cancelledDuplicate.cancel(); duplicateGate.open()
        do { _ = try await cancelledDuplicate.value; XCTFail("cancelled duplicate escaped") } catch {}
        XCTAssertEqual(lease.snapshot().phase,.active, "cancelled duplicate must not close the first lease")
        XCTAssertEqual(releaseWitnesses[lease.id]?.releasedModelIDs, [])
        lease.closeAndCancel()
        XCTAssertGreaterThan(value.transaction.managedMediaReservationCountForTesting,0)
        XCTAssertNil(tracking.outcome)
        gate.release()
        do { _ = try await task.value; XCTFail("cancelled preparation escaped") } catch {}
        actual.loopForTesting.onEngineQueueSync { tracking.beforeFenceForTesting = nil }
        await lease.joinFromOutside()
        let witness = try XCTUnwrap(releaseWitnesses[lease.id])
        await fulfillment(of: [witness.completed], timeout: 5)
        XCTAssertEqual(releaseWitnesses[lease.id]?.releasedModelIDs, ["managed-mimo-fixture"])
        XCTAssertEqual(value.transaction.managedMediaReservationCountForTesting,0)
        try await drain(value,bundle,actual)
    }

    func testLatePreparationAfterOwnerCloseCannotSubmitOrAdvanceConstruction() async throws {
        let (value,bundle,actual) = try await published()
        let tracking = try XCTUnwrap(actual.loopForTesting.nativeShutdownState)
        let gate = Gate(expectation(description:"late preparation"))
        defer { gate.release() }
        actual.loopForTesting.onEngineQueueSync { tracking.beforeFenceForTesting = { _ in gate.hold() } }
        let epoch = value.transaction.snapshot().constructionEpoch
        let mediaInput = input(), mediaPolicy = try policy()
        let container = try XCTUnwrap(value.container.autoregressive)
        let task = Task { try await value.transaction.prepareDecodedMedia(mediaInput,policy:mediaPolicy,
            expectedContainer:container,expectedBridge:bundle.bridge) }
        await fulfillment(of:[gate.entered],timeout:10)
        value.load.revoke()
        if case .pending(.activeOperations) = await value.load.finishFailureAfterUnwind() {} else {
            XCTFail("live preparation was mistaken for retirement")
        }
        XCTAssertTrue(value.transaction.snapshot().hasContainer)
        XCTAssertGreaterThan(value.transaction.managedMediaReservationCountForTesting,0)
        gate.release()
        do { _ = try await task.value; XCTFail("late preparation escaped closed owner") } catch {}
        actual.loopForTesting.onEngineQueueSync { tracking.beforeFenceForTesting = nil }
        XCTAssertEqual(value.transaction.snapshot().constructionEpoch,epoch)
        XCTAssertEqual(value.transaction.managedMediaReservationCountForTesting,0)
        try await drain(value,bundle,actual)
    }

    func testRequiredPreparationFenceFailureCannotBeRehabilitatedByLaterFence() async throws {
        allowedFault = "testRequiredPreparationFenceFailureCannotBeRehabilitatedByLaterFence"
        let (value,bundle,actual) = try await published()
        let tracking = try XCTUnwrap(actual.loopForTesting.nativeShutdownState)
        var attempts = 0
        actual.loopForTesting.onEngineQueueSync {
            tracking.beforeFenceForTesting = { _ in
                attempts += 1
                if attempts == 1 { throw FixtureError.injectedFence }
            }
        }
        do {
            _ = try await value.transaction.prepareDecodedMedia(input(),policy:policy(),
                expectedContainer:XCTUnwrap(value.container.autoregressive),expectedBridge:bundle.bridge)
            XCTFail("failed required fence accepted")
        } catch {}
        guard case .incomplete(let fault)? = tracking.outcome else { return XCTFail("missing permanent fault") }
        XCTAssertEqual(fault.reason,.nativeWorkFailed)
        actual.loopForTesting.onEngineQueueSync { XCTAssertEqual(attempts,1) }
        XCTAssertGreaterThan(value.transaction.managedMediaReservationCountForTesting,0)
        guard case .retainedFault = await value.load.finishFailureAfterUnwind() else {
            return XCTFail("failed preparation refunded or retried")
        }
        XCTAssertTrue(value.transaction.snapshot().hasContainer)
        XCTAssertTrue(value.transaction.snapshot().hasBundle)
        XCTAssertGreaterThan(value.transaction.managedMediaReservationCountForTesting,0)
        // Injected refusal of a required real-work fence, NOT proof of a
        // physical backend failure. This selector owns its fresh process exit.
    }

    func testSealedBindRevalidatesExplicitAndModuleGenerationInvalidation() async throws {
        // Empty updates exercise the actual overrides without changing tensor
        // values. This does not authorize mutation during active generation.
        for invalidation in 0..<3 {
            let (value,bundle,actual) = try await published()
            let container = try XCTUnwrap(value.container.autoregressive)
            let prepared = try await value.transaction.prepareDecodedMedia(input(),policy:policy(),
                expectedContainer:container,expectedBridge:bundle.bridge)
            try await container.perform { context in
                let model = try XCTUnwrap(context.model as? MiMoV26LoadedModel)
                switch invalidation {
                case 0: model.invalidateMultimodalPreparation()
                case 1: _ = try model.update(parameters: .unflattened([]), verify: [])
                default: _ = try model.update(modules: .unflattened([]), verify: [])
                }
            }
            XCTAssertThrowsError(try actual.submit(prepared.request)) { error in
                XCTAssertEqual(error as? MiMoV26MultimodalError, .invalidatedOwner)
            }
            XCTAssertGreaterThan(value.transaction.managedMediaReservationCountForTesting,0,
                                 "refusal must not fake native retirement")
            actual.discardUnsubmittedNativeMedia(try XCTUnwrap(prepared.request.multimodal))
            XCTAssertEqual(value.transaction.managedMediaReservationCountForTesting,0)
            try await drain(value,bundle,actual)
        }
    }

    func testAllSubmitOverloadsRefuseSealedPromptBudgetPayloadMutationAndReplay() async throws {
        let (value,bundle,actual) = try await published()
        let (foreign,foreignBundle,foreignEngine) = try await published(media:false)
        let prepared = try await value.transaction.prepareDecodedMedia(input(),policy:policy(),
            expectedContainer:XCTUnwrap(value.container.autoregressive),expectedBridge:bundle.bridge)
        let deadline = CBv2FirstTokenDeadlineAdmission(deadline: .now.advanced(by: .seconds(60)),
            conservativePrefillTokensPerSecond:1000,conservativeDecodeTokensPerSecond:1000)
        for mutation in 0..<4 {
            var changed = prepared.request
            switch mutation {
            case 0: changed.maxTokens = 0
            case 1: changed.promptTokens = []
            case 2:
                changed.multimodal!.embeddings = { [] }
                changed.maxTokens = 0
            default:
                changed.multimodal!.spans = []
                changed.promptTokens = []
            }
            XCTAssertThrowsError(try actual.submitWithNativeRetirement(changed))
            do {
                _ = try await actual.submit(changed,firstTokenDeadline:deadline)
                XCTFail("invalid sealed handoff returned an admitted/acknowledged deadline result")
            } catch {}
        }
        do {
            _ = try await foreignEngine.submit(prepared.request,firstTokenDeadline:deadline)
            XCTFail("foreign engine accepted the seal")
        } catch {}
        let submitted = try actual.submitWithNativeRetirement(prepared.request)
        for await _ in submitted.events {}
        await submitted.retirement.wait()
        var replay = prepared.request; replay.maxTokens = 0
        XCTAssertThrowsError(try actual.submit(replay))
        do {
            _ = try await actual.submit(replay,firstTokenDeadline:deadline)
            XCTFail("disposed replay accepted by deadline shortcut")
        } catch {}
        XCTAssertEqual(value.transaction.managedMediaReservationCountForTesting,0)
        try await drain(value,bundle,actual)
        try await drain(foreign,foreignBundle,foreignEngine)
    }

    func testFreshOwnedContentRefusalsInvokeReleaseAndJoinExactlyOnce() async throws {
        let (value,bundle,actual) = try await published()
        for badBudget in [true,false] {
            let (acquired,lease) = acquisition(value,bundle)
            let request = ChatCompletionRequest(model:"managed-mimo-fixture",messages:[],
                max_tokens:badBudget ? 4 : 3,logprobs:badBudget ? nil : true)
            do {
                _ = try await value.load.submitDecodedMedia(input(),request:request,acquired:acquired)
                XCTFail("unsupported control accepted")
            } catch {
                XCTAssertEqual(error as? MiMoV26ServingLoadError, .managedLoadRequired)
            }
            let witness = try XCTUnwrap(releaseWitnesses[lease.id])
            await fulfillment(of:[witness.completed],timeout:5)
            await lease.joinFromOutside()
            XCTAssertEqual(witness.releasedModelIDs,["managed-mimo-fixture"])
            XCTAssertEqual(lease.snapshot().phase,.completed)
            XCTAssertFalse(lease.snapshot().hasOutstandingHandoff)
            XCTAssertEqual(value.transaction.managedMediaReservationCountForTesting,0)
        }
        try await drain(value,bundle,actual)
    }

    func testForeignRefusalLeavesFreshAcquisitionForItsActualOwner() async throws {
        let (first,firstBundle,firstEngine) = try await published()
        let (second,secondBundle,secondEngine) = try await published()
        let (acquired,lease) = acquisition(second,secondBundle)
        let witness = try XCTUnwrap(releaseWitnesses[lease.id])
        do {
            _ = try await first.load.submitDecodedMedia(input(),
                request:.init(model:"managed-mimo-fixture",messages:[],max_tokens:3),acquired:acquired)
            XCTFail("foreign acquisition accepted")
        } catch {
            XCTAssertEqual(error as? MiMoV26ServingLoadError,.nativeOwnerMismatch)
        }
        XCTAssertEqual(lease.snapshot().phase,.active)
        XCTAssertEqual(witness.releasedModelIDs,[])
        // The real owner can still adopt it; its deliberate cold content
        // refusal must invoke the actual bound callback exactly once.
        do {
            _ = try await second.load.submitDecodedMedia(input(),
                request:.init(model:"managed-mimo-fixture",messages:[],max_tokens:4),acquired:acquired)
            XCTFail("mismatched budget accepted")
        } catch {
            XCTAssertEqual(error as? MiMoV26ServingLoadError,.managedLoadRequired)
        }
        await fulfillment(of:[witness.completed],timeout:5)
        await lease.joinFromOutside()
        XCTAssertEqual(witness.releasedModelIDs,["managed-mimo-fixture"])
        try await drain(first,firstBundle,firstEngine)
        try await drain(second,secondBundle,secondEngine)
    }

    func testAlreadyCancelledFreshAcquisitionUsesTypedColdDisposal() async throws {
        let (value,bundle,actual) = try await published()
        let (acquired,lease) = acquisition(value,bundle)
        let gate = NativeLocalTaskStartGate(), mediaInput = input()
        let task = Task {
            await gate.wait()
            return try await value.load.submitDecodedMedia(mediaInput,
                request:.init(model:"managed-mimo-fixture",messages:[],max_tokens:3),acquired:acquired)
        }
        task.cancel(); gate.open()
        do { _ = try await task.value; XCTFail("already-cancelled request escaped") } catch {}
        let witness = try XCTUnwrap(releaseWitnesses[lease.id])
        await fulfillment(of:[witness.completed],timeout:5)
        await lease.joinFromOutside()
        XCTAssertEqual(witness.releasedModelIDs,["managed-mimo-fixture"])
        XCTAssertEqual(lease.snapshot().phase,.completed)
        XCTAssertFalse(lease.snapshot().hasOutstandingHandoff)
        XCTAssertEqual(value.transaction.managedMediaReservationCountForTesting,0)
        try await drain(value,bundle,actual)
    }

}
