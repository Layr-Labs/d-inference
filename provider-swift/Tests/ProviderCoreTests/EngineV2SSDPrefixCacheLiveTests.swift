// Copyright © 2026 Eigen Labs.
//
// LIVE (weight-gated) validation of the v0.7.5 encrypted SSD KV-offload
// prefix cache on real gpt-oss-20b weights, through the provider's own
// construction path (`EngineV2Factory.makeProductionEngine(prefixCache:)`
// + `EngineV2Bridge(ssdPrefixCache:)` — exactly what the slot factory
// wires for a funded model with the SSD tier at its default):
//
//   (a) OFFLOAD PROOF — turn 1 (≥2.5k-token prompt, past gpt-oss's
//       adoption floor) donates on completion: encrypted `.dbk3` block
//       files appear on disk under HMAC-tag names, and the cache retains
//       ZERO resident bytes (RAM stays with live serving).
//   (b) FROM-DISK ADOPTION — turn 2 stages the blocks back from disk
//       (`prefixCacheHitTokens > 0`) and its greedy output is
//       BYTE-IDENTICAL to a cache-off engine's run of the same turn.
//   (c) CROSS-ENGINE-RESTART WARMTH (the feature) — the engine + bridge
//       are torn down IN-PROCESS (which closes the cache — the model-
//       unload path), a fresh cache instance over the SAME directory +
//       install key rebuilds its index by directory scan, a fresh engine
//       adopts from disk with the same exactness. No wipe.
//   (d) TTL — a cache whose clock sits past the 15-minute sliding TTL
//       drops the entries at scan and does not adopt.
//
// TTFT deltas (cold vs warm-from-disk) are recorded to the test log.
//
// Gates: DARKBLOOM_LIVE_MLX_TESTS + DARKBLOOM_LIVE_MLX_GPTOSS; skips
// cleanly when the checkpoint is not in the local HF cache.

import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

@Suite("EngineV2 SSD prefix cache (live)", .serialized)
struct EngineV2SSDPrefixCacheLiveTests {

    static let gptossModelID = "mlx-community/gpt-oss-20b-MXFP4-Q8"
    private static let gib = 1_073_741_824

    // MARK: - Loaded-model harness (same ownership story as the RAM suite)

    private struct LiveModel: @unchecked Sendable {
        let modelID: String
        let container: ModelContainer
        let model: any LanguageModel
        let tokenizer: TokenizerHandle
        let eosTokenIds: Set<Int>
        let layerKinds: [CBv2LayerKind]
        let modelDirectory: URL
    }

    private func loadGptOss() async throws -> LiveModel {
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            throw LiveFixtureSkip.missingMetallib
        }
        guard case .found(let directory) = LiveInferenceFixtures.locate(Self.gptossModelID) else {
            throw LiveFixtureSkip.modelNotInCache(Self.gptossModelID)
        }
        LiveInferenceFixtures.applyMemoryBudget(maxBytes: 48 * Self.gib)
        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory, using: LocalTokenizerLoader())
        let snapshot = await container.perform { ctx in
            EngineV2ModelSnapshot(
                model: ctx.model,
                eosTokenIds: ctx.configuration.eosTokenIds,
                extraEOSTokens: ctx.configuration.extraEOSTokens.sorted())
        }
        let tokenizer: TokenizerHandle = await container.perform { ctx in
            TokenizerHandle(ctx.tokenizer)
        }
        let gptoss = try #require(
            snapshot.model as? GPTOSSModel, "gpt-oss checkpoint must load as GPTOSSModel")
        let eos = ModelEOSPolicy.effectiveEOSTokenIds(
            modelId: "gpt-oss-20b",
            modelType: "gpt_oss",
            base: snapshot.eosTokenIds,
            tokenToId: { tokenizer.inner.convertTokenToId($0) })
        return LiveModel(
            modelID: "gpt-oss-20b",
            container: container,
            model: gptoss,
            tokenizer: tokenizer,
            eosTokenIds: eos,
            layerKinds: gptoss.cbv2LayerKinds,
            modelDirectory: directory)
    }

    static let gemmaQatModelID = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"

    /// Prod gemma-4 checkpoints are VLM builds: load through the VLM
    /// factory and extract the CBv2-adapted text model over the SAME
    /// weight arrays — the identical path the slot factory takes. Layer
    /// kinds ALSO derived config-only (the production SSD construction
    /// path for VLM slots) and pinned equal to engine truth.
    private func loadGemmaQat() async throws -> LiveModel {
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            throw LiveFixtureSkip.missingMetallib
        }
        guard case .found(let directory) = LiveInferenceFixtures.locate(Self.gemmaQatModelID)
        else {
            throw LiveFixtureSkip.modelNotInCache(Self.gemmaQatModelID)
        }
        LiveInferenceFixtures.applyMemoryBudget(maxBytes: 64 * Self.gib)
        let container = try await VLMModelFactory.shared.loadContainer(
            from: directory, using: LocalTokenizerLoader())
        let snapshot = await container.perform { ctx in
            EngineV2ModelSnapshot(
                model: ctx.model,
                eosTokenIds: ctx.configuration.eosTokenIds,
                extraEOSTokens: ctx.configuration.extraEOSTokens.sorted())
        }
        let tokenizer: TokenizerHandle = await container.perform { ctx in
            TokenizerHandle(ctx.tokenizer)
        }
        let extraction = try EngineV2VLMTextExtraction.extractTextModel(
            from: snapshot.model, modelDirectory: directory)
        // The config-only derivation (what the slot factory hands the SSD
        // cache for a VLM slot) must match engine truth.
        let configKinds = EngineV2VLMTextExtraction.cbv2LayerKinds(modelDirectory: directory)
        #expect(configKinds == extraction.model.cbv2LayerKinds,
            "config-only layer kinds drifted from the extracted model's")
        return LiveModel(
            modelID: "gemma-4-26b-qat-4bit",
            container: container,
            model: extraction.model,
            tokenizer: tokenizer,
            eosTokenIds: snapshot.eosTokenIds,
            layerKinds: extraction.model.cbv2LayerKinds,
            modelDirectory: directory)
    }

    // MARK: - SSD cache + bridge construction (the production seam)

    private final class ClockBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: Int64
        init(_ now: Int64) { self._now = now }
        var now: Int64 { lock.withLock { _now } }
        func advance(_ seconds: Int64) { lock.withLock { _now += seconds } }
    }

    /// Direct construction with an injected KEK + directory (the factory's
    /// production body minus Keychain/Secure-Enclave, which a test host
    /// cannot reach) — everything downstream (HMAC names, DBK3 crypto,
    /// TTL, staging) is the production code path.
    private func makeSSDCache(
        live: LiveModel, dir: URL, kek: SymmetricKey, clock: ClockBox,
        ttlSeconds: Int64 = 900
    ) -> SSDPrefixCache {
        let blockSize = PrefixCachePolicy.blockSize
        let config = SSDPrefixCache.Config(
            modelId: live.modelID,
            promptContractID: try! PromptContractIdentity.compute(
                modelDirectory: live.modelDirectory),
            weightHash: "live-test-weights",
            blockSize: blockSize,
            adoptionBoundTokens: PrefixCachePolicy.adoptionBoundTokens(
                layerKinds: live.layerKinds),
            layoutEpoch: SSDBlockStore.layoutEpoch(
                blockSize: blockSize, layerKinds: live.layerKinds),
            root: dir,
            ttlSeconds: ttlSeconds,
            minEffectiveTokens: SSDPrefixCachePolicy.defaultMinEffectiveTokens,
            maxStageBytes: SSDPrefixCachePolicy.defaultMaxStageBytes,
            maxStageMillis: 60_000,  // generous: CI boxes vary
            nowSeconds: { clock.now })
        return SSDPrefixCache(
            config: config, kekKey: kek, kvBudget: nil, diskBudget: SSDDiskBudget(),
            maxWriteBytesPerDay: 0, strictFsync: false,
            diskBudgetBytes: { 1 << 40 })
    }

    private func makeBridge(_ live: LiveModel, ssdCache: SSDPrefixCache?) throws -> EngineV2Bridge {
        let engine = try EngineV2Factory.makeProductionEngine(
            model: live.model,
            tokenizer: live.tokenizer.inner,
            kvBytesCapacity: 24 * Self.gib,
            prefixCache: ssdCache)
        return EngineV2Bridge(
            engine: engine,
            modelId: live.modelID,
            tokenizer: live.tokenizer,
            eosTokenIds: live.eosTokenIds,
            ssdPrefixCache: ssdCache)
    }

    // MARK: - Conversation building (same sizing approach as the RAM suite)

    private func turn1UserText(minTokens: Int, tokenize: ([ChatMessage]) throws -> [Int])
        rethrows -> String
    {
        func line(_ index: Int) -> String {
            "Log entry \(index): sensor channel \(index % 17) reported value "
                + "\(index * 37 % 1000) at tick \(index * 13). Summarize later."
        }
        func render(_ count: Int) -> String {
            "Here is a maintenance log to remember for later questions.\n"
                + (1 ... count).map(line).joined(separator: "\n")
                + "\nAcknowledge that you memorized the log."
        }
        func tokenCount(_ count: Int) throws -> Int {
            try tokenize([ChatMessage(role: "user", content: render(count))]).count
        }
        let probeLines = 64
        let probeTokens = try tokenCount(probeLines)
        let perLine = max(1.0, Double(probeTokens) / Double(probeLines))
        var lines = max(probeLines, Int(Double(minTokens) / perLine) + 1)
        for _ in 0 ..< 8 {
            let tokens = try tokenCount(lines)
            if tokens >= minTokens { return render(lines) }
            let deficit = minTokens - tokens
            lines += max(8, Int(Double(deficit) / perLine * 1.02) + 1)
        }
        return render(lines)
    }

    private struct Conversation {
        let turn1Tokens: [Int]
        let turn2Tokens: [Int]
        let sharedPrefixTokens: Int
    }

    private func buildConversation(_ live: LiveModel, minTurn1Tokens: Int) throws -> Conversation {
        let tokenize: ([ChatMessage]) throws -> [Int] = { messages in
            try live.tokenizer.inner.applyChatTemplate(
                messages: messages.map { ["role": $0.role, "content": $0.content] },
                tools: nil, additionalContext: nil)
        }
        let userText = try turn1UserText(minTokens: minTurn1Tokens, tokenize: tokenize)
        let turn1: [ChatMessage] = [ChatMessage(role: "user", content: userText)]
        let turn2: [ChatMessage] = turn1 + [
            ChatMessage(role: "assistant", content: "Acknowledged. I memorized the log."),
            ChatMessage(role: "user", content: "How many log entries were there? Reply briefly."),
        ]
        let t1 = try tokenize(turn1)
        let t2 = try tokenize(turn2)
        var shared = 0
        while shared < min(t1.count, t2.count), t1[shared] == t2[shared] { shared += 1 }
        return Conversation(turn1Tokens: t1, turn2Tokens: t2, sharedPrefixTokens: shared)
    }

    // MARK: - Turn driver

    private struct TurnResult {
        let text: String
        let ttft: Duration
        let prefixCacheHitTokens: Int
    }

    private func runTurn(
        bridge: EngineV2Bridge,
        live: LiveModel,
        promptTokens: [Int],
        maxTokens: Int,
        requestId: String
    ) async throws -> TurnResult {
        let signal = EngineV2RequestUsageSignal()
        let request = ChatCompletionRequest(
            model: live.modelID,
            messages: [ChatMessage(role: "user", content: "unused — pre-tokenized")],
            temperature: 0,
            max_tokens: maxTokens)
        let started = ContinuousClock.now
        var firstChunkAt: ContinuousClock.Instant?
        var text = ""
        var streamError: String?
        let stream = await bridge.submitTokenized(
            promptTokens: promptTokens,
            request: request,
            requestId: requestId,
            usageSignal: signal)
        for await event in stream {
            switch event {
            case .chunk(let chunk):
                if firstChunkAt == nil { firstChunkAt = .now }
                text += chunk
            case .info:
                break
            case .error(let message):
                streamError = message
            }
        }
        if let streamError {
            Issue.record("[\(requestId)] stream error: \(streamError)")
        }
        return TurnResult(
            text: text,
            ttft: (firstChunkAt ?? .now) - started,
            prefixCacheHitTokens: signal.prefixCacheHitTokens ?? 0)
    }

    /// Donation is write-behind — wait for the on-disk index to hold at
    /// least `blocks` entries.
    private func waitForBlocksOnDisk(
        _ cache: SSDPrefixCache, atLeast blocks: Int, timeout: Duration = .seconds(120)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if cache.index.count >= blocks { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return cache.index.count >= blocks
    }

    private func dbk3Files(under root: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "dbk3" }
    }

    // MARK: - The scenario

    @Test(
        "gpt-oss-20b: donate→disk (RAM freed), from-disk adoption byte-identical, restart warmth, TTL",
        .enabled(if:
            LiveInferenceFixtures.liveTestsEnabled
                && ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_GPTOSS"] != nil)
    )
    func gptOssSSDPrefixCache() async throws {
        let live = try await loadGptOss()
        let blockSize = PrefixCachePolicy.blockSize
        let bound = PrefixCachePolicy.adoptionBoundTokens(layerKinds: live.layerKinds)
        #expect(bound == 1536, "gpt-oss-20b adoption bound drifted: \(bound)")
        #expect(PrefixCachePolicy.isEnabled(environment: [:]))

        // Turn-1 prefix past bound + benefit floor, with whole-block margin
        // (≥ 2.5k tokens — the adoption floor the win concentrates past).
        let minTurn1 = bound + SSDPrefixCachePolicy.defaultMinEffectiveTokens + 3 * blockSize
        let conversation = try buildConversation(live, minTurn1Tokens: minTurn1)
        #expect(conversation.sharedPrefixTokens >= minTurn1)
        let sharedBlocks = conversation.sharedPrefixTokens / blockSize
        let expectedMinHit = sharedBlocks * blockSize - bound
        #expect(expectedMinHit >= SSDPrefixCachePolicy.defaultMinEffectiveTokens)
        print(
            "[ssd-live] turn1=\(conversation.turn1Tokens.count) tok, "
                + "turn2=\(conversation.turn2Tokens.count) tok, "
                + "shared=\(conversation.sharedPrefixTokens) tok, bound=\(bound), "
                + "expectedMinHit=\(expectedMinHit)")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssd-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)  // the per-install key
        let clock = ClockBox(Int64(Date().timeIntervalSince1970))
        let maxTokens = 24

        // ---- Engine #1: donate turn 1 to disk.
        let cacheA = makeSSDCache(live: live, dir: dir, kek: kek, clock: clock)
        let bridgeA = try makeBridge(live, ssdCache: cacheA)

        let turn1 = try await runTurn(
            bridge: bridgeA, live: live, promptTokens: conversation.turn1Tokens,
            maxTokens: maxTokens, requestId: "t1")
        #expect(!turn1.text.isEmpty, "turn 1 produced no content")
        #expect(turn1.prefixCacheHitTokens == 0, "first-ever submission cannot hit")
        // (a) Offload proof: blocks land encrypted on disk…
        let turn1Blocks = conversation.turn1Tokens.count / blockSize
        #expect(await waitForBlocksOnDisk(cacheA, atLeast: turn1Blocks),
            "turn-1 donation never landed on disk (\(cacheA.index.count)/\(turn1Blocks))")
        let files = dbk3Files(under: dir)
        #expect(files.count >= turn1Blocks)
        // …files really are DBK3-encrypted (magic parses, wrong key fails)…
        let sample = try #require(files.first)
        #expect(throws: (any Error).self) {
            _ = try SSDBlockStore.read(from: sample, kekKey: SymmetricKey(size: .bits256))
        }
        _ = try SSDBlockStore.read(from: sample, kekKey: kek)  // right key opens
        // …and RAM is FREED: no resident cache bytes after donation.
        #expect(cacheA.bytesInUse == 0, "SSD tier must retain zero resident block bytes")
        let statsAfterDonate = cacheA.stats()
        print(
            "[ssd-live] donated: blocks=\(statsAfterDonate.blocksWritten) "
                + "bytes=\(statsAfterDonate.bytesWritten) files=\(files.count) "
                + "residentBytes=\(cacheA.bytesInUse)")

        // (b) Same-engine turn 2 adopts FROM DISK (the staging read path —
        // the RAM tier is not present; the only source is the block files).
        let turn2WarmSameEngine = try await runTurn(
            bridge: bridgeA, live: live, promptTokens: conversation.turn2Tokens,
            maxTokens: maxTokens, requestId: "t2-same-engine")
        #expect(turn2WarmSameEngine.prefixCacheHitTokens >= expectedMinHit,
            "same-engine warm turn 2 hit \(turn2WarmSameEngine.prefixCacheHitTokens) (< \(expectedMinHit))")
        #expect(cacheA.bytesInUse == 0, "staging must drain after adoption")

        // ---- (c) RESTART WARMTH: tear down engine+bridge (closes the
        // cache — the model-unload path), rebuild everything fresh over the
        // SAME directory + install key, adopt from disk. No wipe.
        await bridgeA.shutdown()
        #expect(cacheA.isClosed)

        let cacheB = makeSSDCache(live: live, dir: dir, kek: kek, clock: clock)
        cacheB.scanOnDisk()  // the startup recovery protocol
        #expect(cacheB.index.count >= turn1Blocks, "restart scan lost the on-disk index")
        let bridgeB = try makeBridge(live, ssdCache: cacheB)
        let turn2Restart = try await runTurn(
            bridge: bridgeB, live: live, promptTokens: conversation.turn2Tokens,
            maxTokens: maxTokens, requestId: "t2-restart")
        #expect(turn2Restart.prefixCacheHitTokens >= expectedMinHit,
            "cross-engine-restart turn 2 hit \(turn2Restart.prefixCacheHitTokens) (< \(expectedMinHit))")
        await bridgeB.shutdown()

        // ---- Cache-off reference (fresh engine, same weights).
        let bridgeOff = try makeBridge(live, ssdCache: nil)
        let turn2Off = try await runTurn(
            bridge: bridgeOff, live: live, promptTokens: conversation.turn2Tokens,
            maxTokens: maxTokens, requestId: "t2-off")
        await bridgeOff.shutdown()
        #expect(turn2Off.prefixCacheHitTokens == 0)

        // Byte-identical greedy output: warm (same-engine), warm (restart),
        // and cache-off must agree exactly.
        #expect(
            turn2WarmSameEngine.text == turn2Off.text,
            Comment(rawValue:
                "same-engine warm output diverged: warm=\(turn2WarmSameEngine.text.debugDescription) off=\(turn2Off.text.debugDescription)"))
        #expect(
            turn2Restart.text == turn2Off.text,
            Comment(rawValue:
                "restart-warm output diverged: warm=\(turn2Restart.text.debugDescription) off=\(turn2Off.text.debugDescription)"))

        // TTFT deltas (informational).
        print(
            "[ssd-live] TTFT: cold-turn1=\(turn1.ttft) warm-same-engine=\(turn2WarmSameEngine.ttft) "
                + "warm-after-restart=\(turn2Restart.ttft) cache-off=\(turn2Off.ttft) "
                + "(warm Δ vs off: same=\(turn2Off.ttft - turn2WarmSameEngine.ttft), "
                + "restart=\(turn2Off.ttft - turn2Restart.ttft))")

        // ---- (d) TTL: a cache whose clock is past the sliding TTL drops
        // the entries at scan and does not adopt.
        let expiredClock = ClockBox(clock.now + 901)  // > 15-minute TTL
        let cacheC = makeSSDCache(live: live, dir: dir, kek: kek, clock: expiredClock)
        cacheC.scanOnDisk()
        #expect(cacheC.index.count == 0, "TTL-expired entries must be dropped at scan")
        #expect(dbk3Files(under: dir).isEmpty, "TTL-expired files must be unlinked")
        let bridgeC = try makeBridge(live, ssdCache: cacheC)
        let turn2Expired = try await runTurn(
            bridge: bridgeC, live: live, promptTokens: conversation.turn2Tokens,
            maxTokens: maxTokens, requestId: "t2-expired")
        #expect(turn2Expired.prefixCacheHitTokens == 0, "TTL-expired entry must not be adopted")
        #expect(turn2Expired.text == turn2Off.text, "expired-cache run must still be exact (cold)")
        await bridgeC.shutdown()

        let finalStats = cacheC.stats()
        print(
            "[ssd-live] final: ttlExpired=\(finalStats.ttlExpired) hits=\(finalStats.hits) "
                + "misses=\(finalStats.misses) corrupt=\(finalStats.corruptDropped)")
        MLX.Memory.clearCache()
    }

    // MARK: - gemma-4 per-donation gate (live)

    @Test(
        "gemma-qat, DEFAULT config, typical prompt: zero disk writes, serves normally",
        .enabled(if:
            LiveInferenceFixtures.liveTestsEnabled
                && ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_GEMMA"] != nil)
    )
    func gemmaTypicalPromptWritesNothing() async throws {
        let live = try await loadGemmaQat()
        let bound = PrefixCachePolicy.adoptionBoundTokens(layerKinds: live.layerKinds)
        #expect(bound == 25_600, "gemma-4 adoption bound drifted: \(bound)")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssd-live-gemma-neg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = ClockBox(Int64(Date().timeIntervalSince1970))
        let cache = makeSSDCache(
            live: live, dir: dir, kek: SymmetricKey(size: .bits256), clock: clock)
        let bridge = try makeBridge(live, ssdCache: cache)

        // Typical prompt (~1.5k tokens) — WAY under the 26,624-token
        // donation floor: the request serves normally and the tier writes
        // NOTHING; the engine keeps its full live KV grant.
        let conversation = try buildConversation(live, minTurn1Tokens: 1500)
        let turn = try await runTurn(
            bridge: bridge, live: live, promptTokens: conversation.turn1Tokens,
            maxTokens: 16, requestId: "gemma-neg")
        #expect(!turn.text.isEmpty, "typical gemma request must serve normally")
        #expect(turn.prefixCacheHitTokens == 0)
        try? await Task.sleep(for: .seconds(2))  // settle any (wrong) write-behind
        let stats = cache.stats()
        #expect(stats.blocksWritten == 0, "sub-floor gemma donation must write nothing")
        #expect(dbk3Files(under: dir).isEmpty)
        #expect(cache.bytesInUse == 0)
        print("[ssd-live] gemma typical (\(conversation.turn1Tokens.count) tok): "
            + "writes=\(stats.blocksWritten) files=0 ttft=\(turn.ttft)")
        await bridge.shutdown()
        MLX.Memory.clearCache()
    }

    @Test(
        "gemma-qat, DEFAULT config, long context (>26.6k): tail cached, adopted from disk byte-identically",
        .enabled(if:
            LiveInferenceFixtures.liveTestsEnabled
                && ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_GEMMA"] != nil)
    )
    func gemmaLongContextTailCachedAndAdopted() async throws {
        let live = try await loadGemmaQat()
        let blockSize = PrefixCachePolicy.blockSize
        let bound = PrefixCachePolicy.adoptionBoundTokens(layerKinds: live.layerKinds)
        #expect(bound == 25_600)

        // Past the donation floor (bound + 1,024) with whole-block margin.
        let minTurn1 = bound + SSDPrefixCachePolicy.defaultMinEffectiveTokens + 3 * blockSize
        let conversation = try buildConversation(live, minTurn1Tokens: minTurn1)
        #expect(conversation.sharedPrefixTokens >= minTurn1)
        let sharedBlocks = conversation.sharedPrefixTokens / blockSize
        let expectedMinHit = sharedBlocks * blockSize - bound
        #expect(expectedMinHit >= SSDPrefixCachePolicy.defaultMinEffectiveTokens)
        print("[ssd-live] gemma long-context: turn1=\(conversation.turn1Tokens.count) tok, "
            + "shared=\(conversation.sharedPrefixTokens), bound=\(bound), "
            + "expectedMinHit=\(expectedMinHit)")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssd-live-gemma-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = ClockBox(Int64(Date().timeIntervalSince1970))
        let cache = makeSSDCache(
            live: live, dir: dir, kek: SymmetricKey(size: .bits256), clock: clock)
        let bridge = try makeBridge(live, ssdCache: cache)
        let maxTokens = 16

        // Turn 1: the long-context donation crosses the floor ⇒ persists.
        let turn1 = try await runTurn(
            bridge: bridge, live: live, promptTokens: conversation.turn1Tokens,
            maxTokens: maxTokens, requestId: "gemma-t1")
        #expect(!turn1.text.isEmpty)
        let turn1Blocks = conversation.turn1Tokens.count / blockSize
        #expect(await waitForBlocksOnDisk(cache, atLeast: turn1Blocks, timeout: .seconds(300)),
            "gemma long-context donation never landed (\(cache.index.count)/\(turn1Blocks))")
        let stats1 = cache.stats()
        #expect(cache.bytesInUse == 0)
        print("[ssd-live] gemma donated: blocks=\(stats1.blocksWritten) "
            + "bytes=\(stats1.bytesWritten)")

        // Turn 2 adopts FROM DISK (~26.9k matched, ≥1,024 effective).
        let turn2Warm = try await runTurn(
            bridge: bridge, live: live, promptTokens: conversation.turn2Tokens,
            maxTokens: maxTokens, requestId: "gemma-t2-warm")
        #expect(turn2Warm.prefixCacheHitTokens >= SSDPrefixCachePolicy.defaultMinEffectiveTokens,
            "gemma warm turn 2 hit \(turn2Warm.prefixCacheHitTokens) (< 1024)")
        #expect(cache.bytesInUse == 0, "staging must drain after adoption")
        await bridge.shutdown()

        // Cache-off reference: byte-identical greedy output.
        let bridgeOff = try makeBridge(live, ssdCache: nil)
        let turn2Off = try await runTurn(
            bridge: bridgeOff, live: live, promptTokens: conversation.turn2Tokens,
            maxTokens: maxTokens, requestId: "gemma-t2-off")
        await bridgeOff.shutdown()
        #expect(turn2Off.prefixCacheHitTokens == 0)
        #expect(
            turn2Warm.text == turn2Off.text,
            Comment(rawValue:
                "gemma warm output diverged: warm=\(turn2Warm.text.debugDescription) "
                    + "off=\(turn2Off.text.debugDescription)"))
        print("[ssd-live] gemma TTFT: warm=\(turn2Warm.ttft) off=\(turn2Off.ttft) "
            + "(Δ=\(turn2Off.ttft - turn2Warm.ttft)); hitTokens=\(turn2Warm.prefixCacheHitTokens)")
        MLX.Memory.clearCache()
    }
}
