// Copyright © 2026 Eigen Labs.
//
// Shared fixture for the gated LFM2.5-24B-A2B real-weights engine
// qualification suites (batching, prefix reuse, SSD restart, memory envelope,
// prefix latency); the provider-path smoke shares its gates and prompt helpers.
// Every suite builds the PRODUCTION bundle the provider uses for one resident
// model: the provider's own single-slot KV grant (UnifiedMemoryCap with the
// default 4 GiB memory_reserve_gb and the resolved activation reserve), a
// GlobalKVCacheBudget, automatic backend, default checkpoint precision, and
// the SSD complete-checkpoint tier in a test-owned isolated root.
//
// Gates: DARKBLOOM_LIVE_MLX_TESTS, DARKBLOOM_LIVE_LFM25_SNAPSHOT and
// DARKBLOOM_LFM25_QUAL=<suite,...> so exactly one model process runs per
// invocation. Evidence (numerics and content hashes only) goes to
// DARKBLOOM_LFM25_QUAL_OUT when set. Nothing touches the product cache root
// or the Keychain: the SSD root is always a test-owned directory, and a
// persistent key (restart suite only) is read from a test-owned key file.

import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import ProviderCoreFoundation
import Testing

@_spi(Benchmarking) @testable import ProviderCore

enum LFM25Qual {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    static let modelID = EngineV2SupportedModels.lfm25_24bA2BModelID

    static var snapshot: URL? {
        guard LiveInferenceFixtures.liveTestsEnabled,
              let raw = environment["DARKBLOOM_LIVE_LFM25_SNAPSHOT"], !raw.isEmpty
        else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    /// Selected suites, so one `swift test` invocation loads the model once.
    static func selected(_ suite: String) -> Bool {
        guard snapshot != nil, let raw = environment["DARKBLOOM_LFM25_QUAL"] else { return false }
        return raw.split(separator: ",").contains { $0 == Substring(suite) }
    }

    static func chatML(_ user: String) -> String {
        "<|startoftext|><|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n<think>"
    }

    /// `repetitionPenalty` nil keeps the artifact's generation_config default
    /// (1.05); logprobs are reported from the RAW logits, so a test that
    /// reasons about decision margins pins it to 1.0 (pure argmax). The
    /// prompt itself is passed as tokens; `userContent` only fills the
    /// request's required message.
    static func request(
        maxTokens: Int, topLogprobs: Int = 0, repetitionPenalty: Float? = nil,
        userContent: String = "qualification"
    ) throws -> ChatCompletionRequest {
        var logprobs = topLogprobs > 0 ? ",\"logprobs\":true,\"top_logprobs\":\(topLogprobs)" : ""
        if let repetitionPenalty { logprobs += ",\"repetition_penalty\":\(repetitionPenalty)" }
        return try JSONDecoder().decode(ChatCompletionRequest.self, from: Data("""
            {"model":"\(modelID)","messages":[{"role":"user","content":"\(userContent)"}],
             "max_tokens":\(maxTokens),"temperature":0\(logprobs)}
            """.utf8))
    }

    /// Deterministic synthetic records (no user content), ~17 tokens each.
    static func records(_ range: Range<Int>, salt: Int = 0) -> String {
        range.map { index in
            let k = index + salt * 1_000
            return "Record \(k): warehouse \(k % 13) logged \(k * 7 % 97) crates of part \(k % 29)."
        }.joined(separator: " ")
    }

    static func sha(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// Characters shared before the first difference (content-free metric).
    static func commonPrefix(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }

    static func gib(_ bytes: Int) -> Double { Double(bytes) / 1_073_741_824 }

    static func writeEvidence(_ name: String, _ object: Any) {
        guard let raw = environment["DARKBLOOM_LFM25_QUAL_OUT"], !raw.isEmpty else { return }
        let dir = URL(fileURLWithPath: raw, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("\(name).json"))
        }
    }
}

/// The real artifact loaded once per process through the provider loader.
struct LFM25Loaded: @unchecked Sendable {
    let snapshot: URL
    let info: ModelInfo
    let container: ModelContainer
    let sizing: SlotSizingSnapshot
    let weightHash: String
    let tokenizer: TokenizerHandle
    let promptContract: String
    let loadSeconds: Double

    static func load() async throws -> LFM25Loaded {
        let snapshot = try #require(LFM25Qual.snapshot)
        let hub = snapshot.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let info = try #require(ModelScanner.scanAllModels(in: hub, environment: [:])
            .first { $0.id == LFM25Qual.modelID })
        try #require(EngineV2SupportedModels.isSupported(model: info))
        _ = try #require(LiveInferenceFixtures.ensureMetallibColocated())
        MLXMemoryGuard.configureOnce()
        let start = Date()
        let container = try await ModelContainerLoading.loadContainer(from: snapshot, modelID: info.id)
        let loadSeconds = Date().timeIntervalSince(start)
        let sizing = await SlotSizingSnapshot.build(
            container: container, modelPath: snapshot, fallbackDefaultMaxTokens: 4096)
        let weightHash = try #require(WeightHasher.computeHash(snapshotDir: snapshot, modelID: info.id))
        let tokenizer = await container.perform { TokenizerHandle($0.tokenizer) }
        return LFM25Loaded(
            snapshot: snapshot, info: info, container: container, sizing: sizing,
            weightHash: weightHash, tokenizer: tokenizer,
            promptContract: try PromptContractIdentity.compute(modelDirectory: snapshot),
            loadSeconds: loadSeconds)
    }

    func encode(_ text: String) -> [Int] {
        tokenizer.inner.encode(text: text, addSpecialTokens: false)
    }
}

/// One production serving slot (bridge + the provider's own memory policy).
struct LFM25Slot: @unchecked Sendable {
    let bridge: EngineV2Bridge
    let kvBudget: GlobalKVCacheBudget
    let kvBytesCapacity: Int
    let activationReserveBytes: UInt64
    let configReserveBytes: UInt64
    let store: SSDHybridCheckpointStore?

    /// Provider defaults: `memory_reserve_gb` 4, activation reserve resolved
    /// for the serving set {LFM} (unmeasured -> the 5.5 GiB default).
    static func make(
        _ model: LFM25Loaded, maxConcurrent: Int, cacheRoot: URL,
        checkpointPrecision: String = "balanced",
        identityTag: String = "lfm25-qual",
        keyLoader: SSDCacheKeyMaterial.PersistentLoader? = nil
    ) async throws -> LFM25Slot {
        let configReserve = ProviderLoop.memoryReserveBytes(forGiB: 4)
        let reserve = UnifiedMemoryCap.resolvedActivationReserveBytes(
            env: [:], modelIDs: [LFM25Qual.modelID])
        let budget = GlobalKVCacheBudget(
            activationReserveBytes: reserve, configReserveBytes: configReserve)
        let capacity = Int(UnifiedMemoryCap.kvBudgetBytes(
            residentWeightBytes: UInt64(model.sizing.weightsBytes),
            activationReserveBytes: reserve, configReserveBytes: configReserve))
        var environment = [
            KVBackendGuardStore.pathEnvKey: "/dev/null",
            SSDPrefixCacheFactory.testRootEnvironmentKey: cacheRoot.path,
            "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1",
        ]
        // The persistent-key flag is set ONLY together with an injected
        // test key loader, so no path can reach the Keychain.
        if keyLoader != nil { environment["DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY"] = "1" }
        // Labelled test seam: a test process has no runtime-bound binary
        // identity, so the checkpoint identity binds the REAL weight
        // aggregate and prompt contract plus a stable build/numerics tag.
        let identity = CBv2CompleteCheckpointIdentity(
            modelAggregateHash: model.weightHash, promptContractID: model.promptContract,
            buildID: identityTag, numericsFingerprint: "\(identityTag)-\(checkpointPrecision)")
        let bridge = try await EngineV2SlotFactory.makeProductionBundle(
            modelId: model.info.id, modelType: model.info.modelType, isVLM: false,
            modelDirectory: model.snapshot, container: model.container, tokenizer: model.tokenizer,
            sizing: model.sizing, kvBytesCapacity: capacity, maxConcurrentRequests: maxConcurrent,
            kvBudget: budget, activationReserveBytes: reserve,
            checkpointQuantizationConfig: checkpointPrecision, weightHash: model.weightHash,
            specDecPreparation: SpecDecPreparation(
                artifact: nil, status: .disabled(.configDisabled, configured: false)),
            assemblyOverrides: .init(
                promptContractID: model.promptContract, completeCheckpointIdentity: identity,
                completeCheckpointKeyLoader: keyLoader),
            environment: environment, startServingTelemetry: false).bridge
        return LFM25Slot(
            bridge: bridge, kvBudget: budget, kvBytesCapacity: capacity,
            activationReserveBytes: reserve, configReserveBytes: configReserve,
            store: bridge.ssdHybridCheckpointStore)
    }

    func capacity() async -> CBv2CapacitySnapshot { await bridge.capacitySnapshot() }

    /// Waits until the engine owns no request and, when `idle` is given, until
    /// in-use and reserved KV are back at that baseline (page retirement is
    /// asynchronous after the terminal event). A leak is a value that never
    /// returns within the timeout.
    func settled(
        idle: CBv2CapacitySnapshot? = nil, timeoutSeconds: Double = 30
    ) async throws -> CBv2CapacitySnapshot {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        func done(_ s: CBv2CapacitySnapshot) -> Bool {
            s.activeRequests == 0 && s.waitingRequests == 0
                && (idle.map { s.kvBytesInUse == $0.kvBytesInUse && s.kvBytesReserved == $0.kvBytesReserved } ?? true)
        }
        var snapshot = await capacity()
        while !done(snapshot), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            snapshot = await capacity()
        }
        return snapshot
    }

    func waitForWrites(above previous: Int, timeoutSeconds: Double = 20) async throws -> Int {
        guard let store else { return 0 }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var written = store.stats().filesWritten
        while written <= previous, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            written = store.stats().filesWritten
        }
        return written
    }
}

/// One request's observable outcome. Text is kept in memory for equality
/// checks only; evidence records hashes and lengths.
struct LFM25Run: Sendable {
    var id = ""
    var promptTokens = 0
    var text = ""
    var chunks = 0
    var completionTokens = 0
    var finishReason: String?
    var error: String?
    var engine: EngineProfile?
    var prefillTokensSaved: Int?
    var cancelledAfterChunks: Int?
    var seconds = 0.0
    /// Per-token logprobs (only when requested); kept in memory for the
    /// divergence analysis, never written to evidence as text.
    var logprobs: [SSETokenLogprob] = []

    var evidence: [String: Any] {
        var out: [String: Any] = [
            "id": id, "promptTokens": promptTokens, "chunks": chunks,
            "completionTokens": completionTokens, "textSHA": LFM25Qual.sha(text),
            "textChars": text.count, "seconds": (seconds * 1000).rounded() / 1000,
            "finishReason": finishReason ?? "nil", "error": error ?? "nil",
            "prefillTokensSaved": prefillTokensSaved ?? -1,
        ]
        if let cancelledAfterChunks { out["cancelledAfterChunks"] = cancelledAfterChunks }
        if let e = engine {
            out["engine"] = [
                "decodeSteps": e.decodeSteps ?? -1, "batchRowsSum": e.batchRowsSum ?? -1,
                "batchRowsMin": e.batchRowsMin ?? -1, "batchRowsMax": e.batchRowsMax ?? -1,
                "prefillChunks": e.prefillChunks ?? -1, "readmissions": e.readmissions ?? -1,
                "preemptions": e.preemptions ?? -1, "capacityRequeues": e.capacityRequeues ?? -1,
                "finishReason": e.finishReason.map { String(describing: $0) } ?? "nil",
            ]
        }
        return out
    }

    static func run(
        _ slot: LFM25Slot, tokens: [Int], maxTokens: Int, id: String,
        scope: String = "", cacheEnabled: Bool = true,
        donationDemand: SSDCheckpointDonationDemand? = nil,
        cancelAfterChunks: Int? = nil, topLogprobs: Int = 0, repetitionPenalty: Float? = nil
    ) async -> LFM25Run {
        var run = LFM25Run(id: id, promptTokens: tokens.count)
        let profile = RequestProfileBuilder()
        let signal = EngineV2RequestUsageSignal()
        let channel = topLogprobs > 0 ? EngineV2LogprobsChannel() : nil
        let start = Date()
        do {
            let stream = try await slot.bridge.submitTokenized(
                promptTokens: tokens,
                request: try LFM25Qual.request(
                    maxTokens: maxTokens, topLogprobs: topLogprobs, repetitionPenalty: repetitionPenalty),
                requestId: id, cacheScope: scope, cacheEnabled: cacheEnabled,
                logprobsChannel: channel, usageSignal: signal, donationDemand: donationDemand,
                firstContentDeadline: nil, profile: profile)
            for await event in stream {
                switch event {
                case .chunk(let text):
                    run.text += text
                    run.chunks += 1
                    if let limit = cancelAfterChunks, run.chunks == limit {
                        await slot.bridge.cancel(requestId: id)
                        run.cancelledAfterChunks = limit
                    }
                case .info(_, let completion, _, let finish):
                    run.completionTokens = completion
                    run.finishReason = finish
                case .error(let message):
                    run.error = message
                case .terminal(_, let message, _, let completion):
                    run.error = message
                    run.completionTokens = completion
                }
            }
        } catch {
            run.error = String(describing: error)
        }
        run.seconds = Date().timeIntervalSince(start)
        run.logprobs = channel?.drain() ?? []
        run.engine = profile.wireObject().engine
        run.prefillTokensSaved = signal.prefixCachePrefillTokensSaved
        return run
    }
}

extension CBv2CapacitySnapshot {
    var evidence: [String: Any] {
        var out: [String: Any] = [
            "activeRequests": activeRequests, "waitingRequests": waitingRequests,
            "kvBytesInUse": kvBytesInUse, "kvBytesReserved": kvBytesReserved,
            "kvBytesCapacity": kvBytesCapacity, "kvBytesBackendCapacity": kvBytesBackendCapacity,
            "activeTokens": activeTokens, "stepsExecuted": stepsExecuted,
            "decodeRowsTotal": decodeRowsTotal,
        ]
        if let paged = pagedStorage {
            out["paged"] = [
                "grantBytes": paged.grantBytes, "committedBytes": paged.committedBytes,
                "reservedPageBytes": paged.reservedPageBytes, "livePageBytes": paged.livePageBytes,
                "admissionRefusals": paged.admissionRefusals, "grantRefusals": paged.grantRefusals,
                "allocationFailures": paged.allocationFailures,
            ]
        }
        return out
    }
}

extension SSDHybridCheckpointStats {
    var evidence: [String: Any] {
        [
            "stageConsumptions": stageConsumptions, "misses": misses,
            "consumedPrefixTokens": consumedPrefixTokens, "stages": stages,
            "stagedBytesInUse": stagedBytesInUse, "filesRead": filesRead, "filesWritten": filesWritten,
            "bytesWritten": bytesWritten, "writesDropped": writesDropped, "corruptDropped": corruptDropped,
            "entries": entries, "bytesOnDisk": bytesOnDisk, "writeHostBytesInUse": writeHostBytesInUse,
        ]
    }
}

/// First-difference analysis of two greedy token streams from their logprobs.
struct LFM25Divergence {
    let index: Int?
    let comparedTokens: Int
    let prefixMaxAbsDelta: Float
    /// B=1's chosen logprob minus its logprob for the batched row's choice.
    let referenceGap: Float?
    /// The batched row's chosen logprob minus its logprob for B=1's choice.
    let runGap: Float?

    private static func key(_ entry: SSETokenLogprob) -> String { entry.token + "|" + "\(entry.bytes ?? [])" }
    private static func key(_ top: SSETokenLogprob.Top) -> String { top.token + "|" + "\(top.bytes ?? [])" }

    init(reference: [SSETokenLogprob], run: [SSETokenLogprob]) {
        let count = min(reference.count, run.count)
        comparedTokens = count
        var first: Int?
        var maxDelta: Float = 0
        for i in 0 ..< count {
            if Self.key(reference[i]) != Self.key(run[i]) { first = i; break }
            maxDelta = max(maxDelta, abs(reference[i].logprob - run[i].logprob))
        }
        index = first
        prefixMaxAbsDelta = maxDelta
        if let k = first {
            let ref = reference[k], got = run[k]
            referenceGap = ref.topLogprobs.first { Self.key($0) == Self.key(got) }.map { ref.logprob - $0.logprob }
            runGap = got.topLogprobs.first { Self.key($0) == Self.key(ref) }.map { got.logprob - $0.logprob }
        } else {
            referenceGap = nil
            runGap = nil
        }
    }

    var isIdentical: Bool { index == nil && comparedTokens > 0 }

    /// Top candidates at the first difference (synthetic prompts; local
    /// evidence only, for rows that fail the near-tie criterion).
    func detail(_ reference: [SSETokenLogprob], _ run: [SSETokenLogprob]) -> [String: Any] {
        guard let k = index else { return [:] }
        func tops(_ e: SSETokenLogprob) -> [[String: Any]] {
            e.topLogprobs.map { ["token": $0.token, "logprob": Double($0.logprob)] }
        }
        return ["referenceChosen": reference[k].token, "referenceChosenLogprob": Double(reference[k].logprob),
                "referenceTop": tops(reference[k]), "runChosen": run[k].token,
                "runChosenLogprob": Double(run[k].logprob), "runTop": tops(run[k])]
    }

    func isTopTwoSwap(within nats: Float) -> Bool {
        guard index != nil, let referenceGap, let runGap else { return false }
        return referenceGap >= 0 && referenceGap <= nats && runGap >= 0 && runGap <= nats
    }

    var evidence: [String: Any] {
        [
            "firstDifferentToken": index ?? -1, "comparedTokens": comparedTokens,
            "prefixMaxAbsLogprobDelta": Double(prefixMaxAbsDelta),
            "referenceGapNats": referenceGap.map { Double($0) } ?? -1,
            "runGapNats": runGap.map { Double($0) } ?? -1,
        ]
    }
}
