import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import NIOFoundationCompat
import MLXLMServer
import ProviderCoreFoundation
import XCTest
@testable import MLXLMCommon
@testable import MLXLLM
@testable import MLXVLM
@testable import ProviderCore

/// Source-prepared only. Real native selectors require the explicit lane and a
/// small selected-audio-compatible fixture, not a full target. Pure ledger/
/// claim selectors below do not authenticate/materialize sidecar payloads.
final class MiMoV26ManagedAudioProviderTests: XCTestCase {
    private enum Failure: Error { case inputRequired, debugSeamsRequired, afterInstallation, injected, retirement }
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
    private var registries: [MiMoV26NativeLoadRegistry] = []
    override func tearDown() {
        for registry in registries where !registry.retainedTransactionIDs.isEmpty { _ = Unmanaged.passRetained(registry) }
        registries = []; super.tearDown()
    }
    private func policy() throws -> MiMoV26ServingLoad.DecodedAudioPolicy {
        let limits = MiMoV26MultimodalLimits(maximumMedia:4,maximumVideoFrames:4,maximumPromptTokens:2048,
            maximumMetadataBytes:1 << 20,maximumMetadataNodes:10000,maximumMetadataDepth:32,
            pixels:.init(maximumInputElements:100000,maximumOutputElements:100000,maximumWorkingBytes:1 << 20),
            vision:.init(maximumPatches:256,maximumAttentionScoreElements:131072),
            audio:.init(maximumClips:2,maximumChannels:1,maximumSampleRate:24000,
                maximumInputSamples:48000,maximumResampledSamples:48000,maximumResampleCoefficients:100000,
                maximumMelFrames:256,maximumSegments:4,maximumPaddedMelFrames:256,
                maximumWorkingElements:64_000_000,frontendFrameBlockSize:8,rvqTileFrames:8),
            audioPatch:.init(maximumClips:2,maximumFrames:256,maximumPatches:64,maximumWorkingElements:16_000_000))
        return try .init(media:.init(limits:limits,maximumReservationBytes:8 << 30,
            additionalSystemReserveBytes:4 << 30),maximumSidecarReservationBytes:4 << 30,
            additionalSystemReserveBytes:4 << 30)
    }
    private func metadataLoad(ordinaryBudget: GlobalKVCacheBudget? = nil) throws -> (URL,MiMoV26ServingLoad) {
        try MiMoTestPrerequisites.requireOptIn("MIMO_V26_MANAGED_AUDIO_PROVIDER_TESTS")
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["MIMO_V26_MANAGED_AUDIO_FIXTURE_ROOT"])
        let root = URL(fileURLWithPath:path)
        let configData = try MiMoV26ServingLoad.readMetadata(root.appendingPathComponent("config.json"),limit:1 << 20).bytes
        let config = try JSONDecoder().decode(MiMoV26Configuration.self,from:configData)
        guard config.hiddenSize <= 64, config.numHiddenLayers <= 4, config.vocabularySize > 151674 else {
            throw Failure.inputRequired // never accidentally load the full target
        }
        let load: MiMoV26ServingLoad
        if let ordinaryBudget {
            load = try XCTUnwrap(MiMoV26OrdinaryServingPolicy.inspect(directory:root,budget:ordinaryBudget))
        } else {
            load = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory:root,decodedAudioPolicy:policy()))
        }
        guard load.plan.bundlePlan.tensorBytes <= 128 << 20 else { throw Failure.inputRequired }
        return (root,load)
    }
    private func loaded(ordinaryPolicy: Bool = false) async throws -> Loaded {
        try MiMoTestPrerequisites.requireOptIn("MIMO_V26_SERIAL_NATIVE_TESTS")
        // Real allocator/OS observations, including the production activation floor.
        let budget = ordinaryPolicy ? GlobalKVCacheBudget() : GlobalKVCacheBudget(configReserveBytes:4 << 30)
        let (root,load) = try metadataLoad(ordinaryBudget:ordinaryPolicy ? budget : nil)
        let registry = MiMoV26NativeLoadRegistry()
        registries.append(registry)
        try load.claim(budget:budget,lifecycle:registry.openLifecycle(),registry:registry)
        let container = try await load.load()
        return .init(root:root,load:load,transaction:try XCTUnwrap(load.transaction),
            registry:registry,budget:budget,container:container,
            tokenizer:await container.tokenizerHandle(modelType:"mimo_v2",directory:root),
            sizing:await container.sizing(modelPath:root,defaultMaxTokens:2))
    }
    private func published(ordinaryPolicy: Bool = false) async throws -> (Loaded,ProviderEngineBundle,EngineV2) {
        let value = try await loaded(ordinaryPolicy:ordinaryPolicy)
        let env = ["DARKBLOOM_PREFIX_CACHE":"0","DARKBLOOM_PREFIX_CACHE_MEMORY":"0",
            PrefillDeadlineMode.environmentKey:PrefillDeadlineMode.enforce.rawValue,
            EngineV2Factory.maxPartialPrefillsKey:"1"]
        let intent = try MiMoV26ServingLoad.preparation(mode:.off,externalPath:nil,environment:env)
        let prepared = try await EngineV2SlotFactory.prepareProductionModel(modelId:"audio-fixture",
            isVLM:false,modelDirectory:value.root,container:value.container,specDecPreparation:intent)
        let bundle = try await EngineV2SlotFactory.makeProductionBundle(modelId:"audio-fixture",modelType:"mimo_v2",
            isVLM:false,modelDirectory:value.root,container:value.container,tokenizer:value.tokenizer,
            sizing:value.sizing,kvBytesCapacity:2 << 30,maxConcurrentRequests:1,kvBudget:value.budget,
            kvBackendConfig:"contiguous",prefillDeadlineMode:.enforce,specDecPreparation:intent,
            preparedModel:prepared,environment:env,startServingTelemetry:false)
        _ = try await value.load.sealConstructionForPublication()
        try value.load.commitPublication {}
        let engine = await bundle.bridge.ownedEngine
        return (value,bundle,try XCTUnwrap(engine as? EngineV2))
    }
    private func input() throws -> MiMoV26MultimodalInput {
        let pcm = try MiMoV26DecodedPCM(samples:(0..<2400).map { sin(Float($0)*0.02)*0.05 },
            descriptor:.init(sourceIdentity:"owned-test-pcm",channels:1,frameCount:2400,sampleRate:24000))
        return .init(messages:[.init(role:.user,content:[.audio(pcm),.text("describe")])],
            additionalContext:["enable_thinking":false],maximumOutputTokens:2)
    }
    private func acquisition(_ value: Loaded,_ bundle: ProviderEngineBundle,
        release: @escaping @Sendable () async -> Void = {}) -> (MultiModelBatchSchedulerEngine.AcquiredModel,NativeLocalConsumerLease) {
        let lease = NativeLocalConsumerLease()
        return (.init(tokenizer:value.tokenizer,
            releaseToken:.init(release:{ _ in await release() },modelId:"audio-fixture",nativeConsumerLease:lease),
            modelType:"mimo_v2",container:value.container.autoregressive,isVLM:false,engineV2Bridge:bundle.bridge),lease)
    }
    private func retire(_ value: Loaded) async throws -> MiMoV26NativeRetirementReceipt {
        guard case .retired(let receipt) = await value.load.finishFailureAfterUnwind() else { throw Failure.retirement }
        return receipt
    }
    private func metadataRequest() -> MiMoV26AudioSidecarLoadRequest {
        let object = MiMoV26FilesystemObjectState(device:"metadata",inode:"metadata",bytes:1_872_618_384,
            modifiedSeconds:0,modifiedNanoseconds:0,changedSeconds:0,changedNanoseconds:0)
        return .init(sessionID:UUID(),canonicalRoot:"/metadata-only",mainConfigurationSHA256:String(repeating:"0",count:64),
            configurationSHA256:String(repeating:"1",count:64),headerSHA256:String(repeating:"2",count:64),
            payloadSHA256:MiMoV26AudioTokenizerWeights.selectedPayloadSHA256,configurationObject:object,payloadObject:object,
            fileBytes:1_872_618_384,headerBytes:93048,inputStoredBytes:634_204_160,unusedStoredBytes:1_238_321_176,
            largestInputBytes:8_388_608,inputTensorCount:389,unusedTensorCount:439,requiredLoadBytes:3_879_023_504)
    }
    private final class Usage: @unchecked Sendable {
        let lock = NSLock()
        private var available: UInt64 = 32 << 30
        private var next: (@Sendable () -> Void)?
        func setAvailable(_ value: UInt64) { lock.withLock { available = value } }
        func arm(_ action: @escaping @Sendable () -> Void) { lock.withLock { next = action } }
        func prepare() {
            let action = lock.withLock { let value = next; next = nil; return value }
            action?()
        }
        func read() -> ProcessMemoryLedger.Usage {
            lock.withLock { .init(activeBytes:0,cacheBytes:0,systemAvailableBytes:available) }
        }
        func snapshot() -> GlobalKVCacheBudget.MemorySnapshot {
            prepare()
            return .init(total:32 << 30,active:0,cache:0,systemAvailable:32 << 30)
        }
    }

    func testRealLedgerSidecarCapacityAndStalePolicyAreOrdinaryWithoutRefundOrOwnerLoss() throws {
        let usage = Usage(), request = metadataRequest()
        let ledger = ProcessMemoryLedger(policy:.init(epoch:1,capBytes:16 << 30,reserveBytes:1 << 30),
            prepareUsage:{ usage.prepare() },readUsage:{ usage.read() })
        let owner = try MiMoV26AudioSidecarReservation(request:request,maximumBytes:4 << 30,
            additionalSystemReserveBytes:2 << 30,ledger:ledger)
        usage.setAvailable(0)
        XCTAssertThrowsError(try owner.validateActive()) {
            XCTAssertEqual($0 as? MiMoV26MultimodalError,.reservationRejected)
        }
        XCTAssertEqual(owner.chargedBytesForTesting,request.requiredLoadBytes)
        XCTAssertEqual(ledger.snapshot().materializedBytes,0)
        usage.setAvailable(32 << 30)
        usage.arm { _ = ledger.updatePolicy(.init(epoch:2,capBytes:16 << 30,reserveBytes:1 << 30)) }
        XCTAssertThrowsError(try owner.validateActive()) {
            XCTAssertEqual($0 as? MiMoV26MultimodalError,.reservationRejected)
        }
        XCTAssertEqual(owner.chargedBytesForTesting,request.requiredLoadBytes)
        try owner.validateActive()
        try owner.retireAfterNativeAliasesReleased() // METADATA ONLY; no codec/native aliases ever existed.
        XCTAssertEqual(ledger.snapshot().chargedBytes,0)
        XCTAssertEqual(ledger.snapshot().ownerCount,0)
        // Combined native mid-preparation capacity witness remains pending;
        // these actual ledger refusals are not a simulated engine success.
    }

    func testStopDuringActualSidecarClaimRetainsLateReservationUntilColdProof() async throws {
        let (_,load) = try metadataLoad(), registry = MiMoV26NativeLoadRegistry()
        registries.append(registry)
        let usage = Usage()
        let budget = GlobalKVCacheBudget(configReserveBytes:4 << 30,memorySnapshot:{ usage.snapshot() })
        let life = try registry.openLifecycle()
        let transaction = try registry.install(request:load.request,budget:budget,lifecycle:life)
        try transaction.claimPermit()
        let audio = try XCTUnwrap(load.audioLoadRequest)
        // Existing injected read runs before the ledger lock. Close while the
        // actual new sidecar constructor owns an unfinished admitted result.
        usage.arm { _ = try? registry.closeLifecycle(life) }
        XCTAssertThrowsError(try transaction.claimAudioSidecar(request:audio,policy:policy()))
        XCTAssertEqual(transaction.snapshot().audioSessionID,audio.sessionID)
        XCTAssertEqual(transaction.snapshot().audioChargedBytes,audio.requiredLoadBytes)
        XCTAssertEqual(transaction.snapshot().activeOperations,0)
        XCTAssertFalse(registry.hasRetainedFault)
        guard case .retired(let receipt) = await transaction.retire() else { return XCTFail("actual cold proof missing") }
        XCTAssertEqual(receipt.construction.completion,.noNativeSubmission)
        XCTAssertEqual(receipt.audioSessionID,audio.sessionID)
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes,0)
        // Header/ledger-only fixture, never full authentication or native load.
    }

    #if DEBUG
    func testNativeAudioReleaseAcceptsOpenRouterPCM8WAVThroughAuthenticatedHTTP() async throws {
        @Sendable func phase(_ message: String) {
            FileHandle.standardError.write(Data(("MiMo audio qualification: " + message + "\n").utf8))
        }
        phase("loading genuine codec with ordinary policy")
        let (value,bundle,actual) = try await published(ordinaryPolicy:true)
        phase("native engine published")
        let binding = try await bundle.bridge.nativeMiMoDecodedAudioBinding()
        XCTAssertTrue(binding.load === value.load)
        let before = actual.stepCount
        func u16(_ n: UInt16) -> [UInt8] { [UInt8(truncatingIfNeeded:n),UInt8(truncatingIfNeeded:n >> 8)] }
        func u32(_ n: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded:n >> ($0 * 8)) } }
        // Same 22.05 kHz, unsigned PCM8, mono and 47048 samples as the
        // OpenRouter failure. Use synthetic samples, never user recordings.
        let samples = (0..<47048).map { UInt8(128 + Int(40 * sin(Double($0) * 0.025))) }
        let fmt = u16(1) + u16(1) + u32(22050) + u32(22050) + u16(1) + u16(8)
        let waveBody = Array("WAVEfmt ".utf8) + u32(16) + fmt + Array("data".utf8) + u32(UInt32(samples.count)) + samples
        let wave = Data(Array("RIFF".utf8) + u32(UInt32(waveBody.count)) + waveBody)
        let body = try JSONSerialization.data(withJSONObject:[
            "model":"audio-fixture","stream":true,"stream_options":["include_usage":true],
            "enable_thinking":false,"temperature":0,"max_tokens":3,
            "messages":[["role":"user","content":[
                ["type":"text","text":"What do you hear in this audio?"],
                ["type":"input_audio","input_audio":["format":"wav","data":wave.base64EncodedString()]]
            ]]]])
        let lease = NativeLocalConsumerLease()
        let app = makeLocalInferenceApplication(config:.init(host:"127.0.0.1",port:0,authToken:"audio-test-token"),
            defaultMaxTokens:3,acquire:{ _ in
                .init(tokenizer:value.tokenizer,
                    releaseToken:.init(release:{ _ in },modelId:"audio-fixture",nativeConsumerLease:lease),
                    modelType:"mimo_v2",container:value.container.autoregressive,isVLM:false,engineV2Bridge:bundle.bridge)
            },tokenizerProvider:{ _ in .init(tokenizer:value.tokenizer,modelType:"mimo_v2") },
            availableModels:{ ["audio-fixture"] },mtpSlots:{ [] },
            modelTypeProvider:{ _ in "mimo_v2" })
        phase("sending authenticated PCM8 WAV")
        try await app.test(.router) { client in
            try await client.execute(uri:"/v1/chat/completions",method:.post,
                headers:[.contentType:"application/json",.authorization:"Bearer audio-test-token"],
                body:ByteBuffer(bytes:body)) { response in
                let text = String(buffer:response.body)
                phase("HTTP status " + String(response.status.code))
                XCTAssertEqual(response.status,.ok,text)
                XCTAssertTrue(text.contains("data: [DONE]"))
                var generated = 0
                for line in text.split(separator:"\n") where line.hasPrefix("data: {") {
                    let object = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(line.dropFirst(6).utf8)) as? [String:Any])
                    XCTAssertNil(object["error"])
                    if let usage = object["usage"] as? [String:Any] {
                        generated = max(generated,usage["completion_tokens"] as? Int ?? 0)
                    }
                }
                XCTAssertGreaterThan(generated,0)
            }
        }
        phase("HTTP stream finished; joining owner")
        if lease.snapshot().phase == .awaitingBinding {
            _ = try lease.abandonUnstartedHandoff()
        }
        await lease.joinFromOutside()
        phase("owner joined")
        XCTAssertGreaterThan(actual.stepCount,before)
        XCTAssertEqual(lease.snapshot().phase,.completed)
        XCTAssertEqual(value.transaction.managedMediaReservationCountForTesting,0)
        XCTAssertNil(actual.nativeCompletionFault)
        let receipt = try await retire(value)
        XCTAssertEqual(receipt.audioSessionID,binding.receipt.request.sessionID)
        XCTAssertEqual(value.budget.processLedger.snapshot().chargedBytes,0)
    }

    func testChatAndResponsesRouteEncodedAudioThroughActualNativeScheduler() async throws {
        let (value, bundle, actual) = try await published()
        let audio = try await bundle.bridge.nativeMiMoDecodedAudioBinding()
        XCTAssertTrue(audio.load === value.load)
        XCTAssertEqual(audio.receipt.request, value.load.audioLoadRequest)
        let engineID = actual.nativeShutdownEngineID
        let epoch = value.transaction.snapshot().constructionEpoch
        let sidecarBytes = try XCTUnwrap(value.load.audioLoadRequest).requiredLoadBytes
        func u16(_ x: UInt16) -> [UInt8] {
            [UInt8(truncatingIfNeeded: x), UInt8(truncatingIfNeeded: x >> 8)]
        }
        func u32(_ x: UInt32) -> [UInt8] {
            [UInt8(truncatingIfNeeded: x), UInt8(truncatingIfNeeded: x >> 8),
             UInt8(truncatingIfNeeded: x >> 16), UInt8(truncatingIfNeeded: x >> 24)]
        }
        let pcm = (0..<2400).flatMap { index in u16(UInt16(truncatingIfNeeded: index % 32)) }
        let fmt = u16(1) + u16(1) + u32(24000) + u32(48000) + u16(2) + u16(16)
        let waveBody = Array("WAVEfmt ".utf8) + u32(16) + fmt
            + Array("data".utf8) + u32(UInt32(pcm.count)) + pcm
        let wave = Data(Array("RIFF".utf8) + u32(UInt32(waveBody.count)) + waveBody)
        for responses in [false, true] {
            let messages: [[String: Any]] = [["role": "user", "content": [
                ["type": "input_audio", "input_audio": ["format": "wav", "data": wave.base64EncodedString()]],
                ["type": responses ? "input_text" : "text", "text": "describe"],
            ]]]
            let body = try JSONSerialization.data(withJSONObject: [
                "model": "audio-fixture", "enable_thinking": false, "temperature": 0,
                responses ? "max_output_tokens" : "max_tokens": 2,
                responses ? "input" : "messages": messages,
            ])
            let request: OpenAIChatCompletionRequest
            let controls: ChatTemplateControls
            if responses {
                let decoded = try JSONDecoder().decode(LocalResponseRequest.self, from: body)
                request = decoded.request.chatCompletionRequest
                controls = decoded.templateControls
            } else {
                request = try ProviderLoop.decodeOpenAIRequest(body)
                controls = ProviderLoop.extractChatTemplateControls(from: body)
            }
            XCTAssertTrue(MediaIngest.hasAudio(request))
            let (acquired, lease) = acquisition(value, bundle)
            let scheduler = MultiModelBatchSchedulerEngine(acquire: { _ in acquired },
                tokenizerProvider: { _ in .init(tokenizer: value.tokenizer, modelType: "mimo_v2") },
                availableModels: { ["audio-fixture"] }, defaultMaxTokens: 2,
                templateControls: controls, modelTypeProvider: { _ in "mimo_v2" })
            let before = actual.stepCount
            let stream = try await scheduler.streamChatCompletion(request: request)
            var infos = 0
            for try await event in stream {
                if case .info(let info) = event {
                    infos += 1
                    XCTAssertGreaterThan(info.promptTokens, 0)
                    XCTAssertGreaterThan(info.completionTokens, 0)
                }
            }
            await lease.joinFromOutside()
            XCTAssertEqual(infos, 1)
            XCTAssertGreaterThan(actual.stepCount, before, "normal encoded-audio route must execute the real native engine")
            XCTAssertEqual(lease.snapshot().phase, .completed)
            XCTAssertEqual(actual.nativeShutdownEngineID, engineID)
            XCTAssertNil(actual.nativeCompletionFault)
            XCTAssertEqual(value.transaction.snapshot().constructionEpoch, epoch)
            XCTAssertEqual(value.transaction.snapshot().audioChargedBytes, sidecarBytes)
            XCTAssertEqual(value.transaction.managedMediaReservationCountForTesting, 0)
        }
        let receipt = try await retire(value)
        XCTAssertEqual(receipt.engine?.engineID, engineID)
        XCTAssertEqual(receipt.audioSessionID, audio.receipt.request.sessionID)
        XCTAssertEqual(value.budget.processLedger.snapshot().chargedBytes, 0)
        XCTAssertTrue(value.registry.retainedTransactionIDs.isEmpty)
    }

    func testActualPCMDeadlineAndHostTailUseSameLeaseAndKeepSidecarUntilJoined() async throws {
        let (value,bundle,actual) = try await published()
        let audio = try await bundle.bridge.nativeMiMoDecodedAudioBinding()
        XCTAssertTrue(audio.load === value.load)
        XCTAssertEqual(audio.receipt.request,value.load.audioLoadRequest)
        let sidecarBytes = try XCTUnwrap(value.load.audioLoadRequest).requiredLoadBytes
        let epoch = value.transaction.snapshot().constructionEpoch
        let initialC = value.budget.processLedger.snapshot().chargedBytes
        XCTAssertEqual(value.transaction.snapshot().audioChargedBytes,sidecarBytes)
        await bundle.bridge._testSeedIsolatedPrefillEwma(0.001)
        let (rejected, rejectedLease) = acquisition(value,bundle)
        let before = actual.stepCount
        do {
            _ = try await value.load.submitDecodedAudioMedia(input(),
                request:.init(model:"audio-fixture",messages:[],max_tokens:2),acquired:rejected,
                firstContentDeadline:.init(relativeBudgetMilliseconds:600_000))
            XCTFail("real atomic deadline was bypassed")
        } catch { XCTAssertEqual(error as? PreContentDeadlineFailure,.deadlineUnreachable) }
        await rejectedLease.joinFromOutside()
        XCTAssertEqual(actual.stepCount,before)
        XCTAssertEqual(value.transaction.managedMediaReservationCountForTesting,0)
        XCTAssertEqual(value.budget.processLedger.snapshot().chargedBytes,initialC)
        XCTAssertNil(actual.nativeCompletionFault)

        let entered = NativeLocalTaskStartGate(), release = NativeLocalTaskStartGate()
        let (acquired,lease) = acquisition(value,bundle) { entered.open(); await release.wait() }
        let stream = try await value.load.submitDecodedAudioMedia(input(),
            request:.init(model:"audio-fixture",messages:[],max_tokens:2),acquired:acquired)
        var infos = 0, failures = 0
        for await event in stream {
            switch event { case .info: infos += 1; case .error,.terminal: failures += 1; default: break }
        }
        await entered.wait()
        XCTAssertEqual(infos,1); XCTAssertEqual(failures,0)
        let contract = try XCTUnwrap(actual.nativeShutdownExecutionContractID)
        do { _ = try await bundle.bridge.shutdownNativeConstruction(expectedEngine:actual,executionContractID:contract) }
        catch MiMoV26NativeBridgeShutdownError.pendingConsumers {
            let tasks = await bundle.bridge.nativeRetirementTaskSnapshot()
            XCTAssertEqual(tasks.sdkQuiescence?.executionContractID,contract)
            for task in tasks.tasks { await task.value }
        }
        let retiring = Task { await value.load.finishFailureAfterUnwind() }
        let deadline = ContinuousClock.now.advanced(by:.seconds(30))
        while value.transaction.snapshot().phase != .draining,
              value.transaction.snapshot().phase != .retired, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(value.transaction.snapshot().phase,.draining)
        XCTAssertFalse(value.transaction.snapshot().audioAliasesDetached)
        XCTAssertEqual(value.transaction.snapshot().audioChargedBytes,sidecarBytes)
        release.open()
        await lease.joinFromOutside()
        guard case .retired(let receipt) = await retiring.value else { return XCTFail("actual post-tail retirement missing") }
        XCTAssertEqual(receipt.audioSessionID,audio.receipt.request.sessionID)
        XCTAssertEqual(value.transaction.snapshot().constructionEpoch,epoch)
        XCTAssertEqual(value.budget.processLedger.snapshot().chargedBytes,0)
        let detached = await value.container.autoregressive!.perform { context in
            (context.model as? MiMoV26LoadedModel)?.resources.audioSidecar == nil
        }
        XCTAssertTrue(detached)
        // State polling controls this test barrier only; the actual returned
        // receipt + joined tasks, not phase/count/timeout, authorize the final assertion.
    }
    #endif

    func testHealthySetupFailureAfterActualInstallBeforeProfileUsesExactColdDetach() async throws {
        let value = try await loaded(), transfer = try XCTUnwrap(value.load.takeAudioInstallation())
        let sidecarBytes = transfer.reservation.request.requiredLoadBytes
        do {
            _ = try await value.transaction.withNativeConstruction { model,scope -> Bool in
                _ = try model.installAudioSidecar(session:transfer.session.consume(),reservation:transfer.reservation,
                    retaining:scope,isCancelled:{ false })
                // Deliberately before registerInstalledAudioReceipt/profile/
                // engine: actual LoadedResources, not host metadata, owns it.
                throw Failure.afterInstallation
            }
            XCTFail("setup veto did not occur")
        } catch { XCTAssertTrue(error is Failure) }
        XCTAssertFalse(value.registry.hasRetainedFault)
        XCTAssertFalse(value.transaction.snapshot().hasEngine)
        XCTAssertFalse(value.transaction.snapshot().hasInstalledAudioReceipt)
        XCTAssertEqual(value.transaction.snapshot().audioChargedBytes,sidecarBytes)
        let installed = await value.container.autoregressive!.perform { context in
            (context.model as? MiMoV26LoadedModel)?.resources.audioSidecar != nil
        }
        XCTAssertTrue(installed)
        let receipt = try await retire(value)
        XCTAssertNil(receipt.engine)
        XCTAssertEqual(receipt.audioSessionID,transfer.reservation.request.sessionID)
        let detached = await value.container.autoregressive!.perform { context in
            (context.model as? MiMoV26LoadedModel)?.resources.audioSidecar == nil
        }
        XCTAssertTrue(detached)
        XCTAssertEqual(value.budget.processLedger.snapshot().chargedBytes,0)
    }

    func testActualInnerRequiredFailureKeepsProviderRequestAndSidecarChargesSticky() async throws {
        try MiMoTestPrerequisites.requireOptIn("MIMO_V26_MANAGED_AUDIO_PROVIDER_FAULT_TEST")
        #if DEBUG
        let (value,bundle,actual) = try await published()
        try await value.container.autoregressive!.perform { context in
            let model = try XCTUnwrap(context.model as? MiMoV26LoadedModel)
            try XCTUnwrap(model.resources.audioSidecar).codec.input.beforeManagedRequiredCompletionForTesting = { phase in
                if case .codesReadback = phase { throw Failure.injected }
            }
        }
        let (acquired,lease) = acquisition(value,bundle)
        do {
            _ = try await value.load.submitDecodedAudioMedia(input(),
                request:.init(model:"audio-fixture",messages:[],max_tokens:2),acquired:acquired)
            XCTFail("failed inner completion submitted PCM")
        } catch { XCTAssertEqual(error as? MiMoV26MultimodalError,.drainFailed) }
        await lease.joinFromOutside() // failed preparation Task actually returned
        XCTAssertNotNil(actual.nativeCompletionFault)
        XCTAssertTrue(value.registry.hasRetainedFault)
        let before = value.budget.processLedger.snapshot().chargedBytes
        XCTAssertGreaterThan(value.transaction.managedMediaChargedBytesForTesting,0)
        XCTAssertEqual(value.transaction.snapshot().audioChargedBytes,value.load.audioLoadRequest?.requiredLoadBytes)
        guard case .retainedFault = await value.load.finishFailureAfterUnwind() else { return XCTFail("fault refunded owner") }
        XCTAssertEqual(value.budget.processLedger.snapshot().chargedBytes,before)
        XCTAssertFalse(value.transaction.snapshot().audioAliasesDetached)
        _ = Unmanaged.passRetained(value.registry)
        // Required readback refusal after actual work, not a physical fault claim.
        #else
        throw Failure.debugSeamsRequired
        #endif
    }
}
