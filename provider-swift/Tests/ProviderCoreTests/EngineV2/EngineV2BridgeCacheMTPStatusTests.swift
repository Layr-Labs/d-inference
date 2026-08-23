// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore


@Suite("EngineV2 lookup receipt terminal coverage")
struct EngineV2LookupReceiptCoverageTests {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [PrefixCacheLookupResult] = []

        func append(_ value: PrefixCacheLookupResult) {
            lock.withLock { values.append(value) }
        }

        var snapshot: [PrefixCacheLookupResult] { lock.withLock { values } }
    }

    private func signal(_ box: Box) -> EngineV2RequestUsageSignal {
        EngineV2RequestUsageSignal(onLookupResolved: box.append)
    }

    @Test("shared-budget rejection emits exactly one final lookup receipt")
    func sharedBudgetRejection() async {
        let box = Box()
        let engine = ScriptedCBv2Engine(script: .manual)
        let bridge = makeBridge(
            engine: engine,
            kvBytesPerToken: 4_000,
            kvBudget: TestBudgets.exhausted())
        _ = await record(await bridge.submitTokenized(
            promptTokens: [1, 2, 3],
            request: makeRequest(maxTokens: 8),
            requestId: "receipt-shared-reject",
            cacheEnabled: true,
            usageSignal: signal(box)))
        #expect(box.snapshot.count == 1)
        #expect(box.snapshot.first?.outcome == .skippedCapacity)
        #expect(box.snapshot.first?.tier == .memory)
        #expect(engine.submitted.isEmpty)
    }

    @Test("engine submit rejection emits exactly one final lookup receipt")
    func engineSubmitRejection() async {
        let box = Box()
        let engine = ScriptedCBv2Engine(script: .throwOnSubmit(
            CBv2KVError.capacityExhausted(needed: 10, available: 1)))
        let bridge = makeBridge(engine: engine)
        _ = await record(await bridge.submitTokenized(
            promptTokens: [1, 2, 3],
            request: makeRequest(maxTokens: 8),
            requestId: "receipt-engine-reject",
            cacheEnabled: true,
            usageSignal: signal(box)))
        #expect(box.snapshot.count == 1)
        #expect(box.snapshot.first?.outcome == .skippedCapacity)
    }

    @Test("teardown without finished emits exactly one final lookup receipt")
    func teardownWithoutFinished() async {
        let box = Box()
        let engine = ScriptedCBv2Engine(script: .stream([
            .delta(text: "partial", tokens: [1], logprobs: nil)
        ]))
        let bridge = makeBridge(engine: engine)
        _ = await record(await bridge.submitTokenized(
            promptTokens: [1, 2, 3],
            request: makeRequest(maxTokens: 8),
            requestId: "receipt-teardown",
            cacheEnabled: true,
            usageSignal: signal(box)))
        #expect(box.snapshot.count == 1)
        #expect(box.snapshot.first?.outcome == .skippedPolicy)
    }

    @Test("cache-disabled path emits once even when terminal usage follows")
    func cacheDisabled() async {
        let box = Box()
        let engine = ScriptedCBv2Engine(script: .stream([
            .finished(
                reason: .stop,
                usage: CBv2Usage(promptTokens: 3, completionTokens: 0))
        ]))
        let bridge = makeBridge(engine: engine)
        _ = await record(await bridge.submitTokenized(
            promptTokens: [1, 2, 3],
            request: makeRequest(maxTokens: 8),
            requestId: "receipt-disabled",
            cacheEnabled: false,
            usageSignal: signal(box)))
        #expect(box.snapshot.count == 1)
        #expect(box.snapshot.first?.outcome == .skippedPolicy)
    }
}

// MARK: - Seeded sampling reproducibility (stable engine ids)

/// STOCHASTIC sampler stub: emitted tokens are a pure function of
/// (sampling.seed, request.id.raw, stepIndex) — the exact key shape the real
/// v2 sampler uses (`SamplerV2.mix`) — so these tests prove end-to-end that
/// seeded outputs reproduce iff the bridge hands the engine a stable id.
private final class StochasticScriptedEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var _submitted: [CBv2Request] = []
    var submitted: [CBv2Request] { lock.withLock { _submitted } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        lock.withLock { _submitted.append(request) }
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        for step in 0..<4 {
            let key = Self.mix(
                seed: request.sampling.seed ?? 0, id: request.id.raw, step: UInt64(step))
            let token = Int(key % 50_000)
            continuation.yield(.delta(text: "t\(token) ", tokens: [token], logprobs: nil))
        }
        continuation.yield(.finished(
            reason: .stop,
            usage: CBv2Usage(promptTokens: request.promptTokens.count, completionTokens: 4)))
        continuation.finish()
        return stream
    }

    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        CBv2CapacitySnapshot(
            activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
            kvBytesCapacity: 0, activeTokens: 0)
    }
    func shutdown() async {}

    /// Same mixing family as the engine sampler's keyed RNG.
    static func mix(seed: UInt64, id: UInt64, step: UInt64) -> UInt64 {
        func splitmix(_ x: UInt64) -> UInt64 {
            var z = x &+ 0x9E37_79B9_7F4A_7C15
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        return splitmix(splitmix(splitmix(seed) ^ id) ^ step)
    }
}

private final class ReceiptNonceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(nonce: String, result: PrefixCacheReadyResult) {
        lock.withLock { values.append("\(nonce):\(result.readyTokens)") }
    }

    var snapshot: [String] { lock.withLock { values } }

    func waitForCount(_ count: Int, timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if snapshot.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return snapshot.count >= count
    }
}

@Suite("EngineV2 seeded sampling reproducibility")
struct EngineV2SeededSamplingTests {

    private func chunks(_ events: [RecordedEvent]) -> [String] {
        events.compactMap {
            if case .chunk(let text) = $0 { return text }
            return nil
        }
    }

    @Test("same seed + same prompt reproduce identical output across submissions")
    func seededOutputReproduces() async {
        let engine = StochasticScriptedEngine()
        let bridge = makeBridge(engine: engine)
        let prompt = [11, 22, 33]

        let (first, _) = await record(await bridge.submitTokenized(
            promptTokens: prompt, request: makeRequest(maxTokens: 8, seed: 42),
            requestId: "req-seed-1"))
        // Interleave an UNRELATED request so the monotonic counter moves —
        // the regression this fix targets: seeded output must not depend on
        // prior traffic.
        _ = await record(await bridge.submitTokenized(
            promptTokens: [9, 9, 9], request: makeRequest(maxTokens: 8),
            requestId: "req-noise"))
        let (second, _) = await record(await bridge.submitTokenized(
            promptTokens: prompt, request: makeRequest(maxTokens: 8, seed: 42),
            requestId: "req-seed-2"))

        #expect(!chunks(first).isEmpty)
        #expect(chunks(first) == chunks(second))
        // The engine saw the SAME stable id on both seeded submissions —
        // that is what keys the RNG stream — and it carries the seeded tag.
        #expect(engine.submitted.count == 3)
        #expect(engine.submitted[0].id == engine.submitted[2].id)
        #expect(engine.submitted[0].id.raw & EngineV2Bridge.seededIdTagBit != 0)
    }

    @Test("sequential identical seeded requests keep receipt callbacks and cleanup isolated")
    func seededReceiptIdentityIsIndependent() async throws {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bridge-receipt-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("aaaaaaaaaaaa", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let layerKinds = [
            CBv2LayerKind(attention: .full, headDim: 4, kvHeads: 1, queryHeads: 1)
        ]
        let cache = SSDPrefixCache(
            config: .init(
                modelId: "receipt-model",
                promptContractID: "receipt-contract",
                weightHash: "receipt-weight",
                blockSize: 8,
                adoptionBoundTokens: 0,
                layoutEpoch: SSDBlockStore.layoutEpoch(
                    blockSize: 8, layerKinds: layerKinds),
                root: root,
                ttlSeconds: 900,
                minEffectiveTokens: 8,
                maxStageBytes: 1 << 20,
                maxStageMillis: 10_000,
                nowSeconds: { 10_000 }),
            kekKey: SymmetricKey(size: .bits256),
            kvBudget: nil,
            diskBudget: SSDDiskBudget(),
            maxWriteBytesPerDay: 0,
            diskBudgetBytes: { 1 << 20 })
        defer { cache.close() }

        let engine = StochasticScriptedEngine()
        let bridge = makeBridge(engine: engine, ssdPrefixCache: cache)
        let callbackBox = ReceiptNonceBox()
        let prompt = [11, 22, 33]
        let request = makeRequest(maxTokens: 8, seed: 42)

        let signalA = EngineV2RequestUsageSignal(onCacheReady: { result in
            callbackBox.append(nonce: "nonce-a", result: result)
        })
        _ = await record(await bridge.submitTokenized(
            promptTokens: prompt,
            request: request,
            requestId: "receipt-a",
            cacheScope: "scope-a",
            usageSignal: signalA))

        let signalB = EngineV2RequestUsageSignal(onCacheReady: { result in
            callbackBox.append(nonce: "nonce-b", result: result)
        })
        _ = await record(await bridge.submitTokenized(
            promptTokens: prompt,
            request: request,
            requestId: "receipt-b",
            cacheScope: "scope-b",
            usageSignal: signalB))

        #expect(engine.submitted.count == 2)
        #expect(engine.submitted[0].id == engine.submitted[1].id)
        #expect(engine.submitted[0].cacheSalt == "scope-a")
        #expect(engine.submitted[1].cacheSalt == "scope-b")
        let receiptA = try #require(engine.submitted[0].prefixCacheReceiptID)
        let receiptB = try #require(engine.submitted[1].prefixCacheReceiptID)
        #expect(receiptA != receiptB)
        #expect(receiptB.raw == receiptA.raw + 1)

        let tokenCount = 64
        let shape = [1, 1, tokenCount, 4]
        let base = MLXArray(0 ..< shape.reduce(1, *)).reshaped(shape).asType(.float16)
        let values = base + 1
        let snapshots: [(keys: MLXArray, values: MLXArray, offset: Int)?] = [
            (keys: base, values: values, offset: tokenCount)
        ]
        eval(base, values)

        // A settles only after B has registered under the same stable sampler
        // id. Its callback must still carry A's nonce, never B's.
        cache.donate(
            requestID: receiptA,
            tokens: Array(0 ..< tokenCount),
            snapshots: snapshots,
            layerKinds: layerKinds,
            cacheSalt: "scope-a")
        #expect(await callbackBox.waitForCount(1))
        #expect(callbackBox.snapshot == ["nonce-a:64"])

        // Accelerate only A's terminal-retention cleanup. It must not remove
        // B's callback before B's differently-scoped donation settles.
        cache.markReadyReceiptTerminal(
            requestID: receiptA, cleanupDelay: .milliseconds(30))
        try? await Task.sleep(for: .milliseconds(100))
        cache.donate(
            requestID: receiptB,
            tokens: Array(0 ..< tokenCount),
            snapshots: snapshots,
            layerKinds: layerKinds,
            cacheSalt: "scope-b")
        #expect(await callbackBox.waitForCount(2))
        #expect(callbackBox.snapshot == ["nonce-a:64", "nonce-b:64"])
    }

    @Test("different seed or different prompt produce different ids (and RNG streams)")
    func seededOutputDiverges() async {
        let engine = StochasticScriptedEngine()
        let bridge = makeBridge(engine: engine)
        _ = await record(await bridge.submitTokenized(
            promptTokens: [1, 2, 3], request: makeRequest(maxTokens: 8, seed: 42),
            requestId: "req-a"))
        _ = await record(await bridge.submitTokenized(
            promptTokens: [1, 2, 3], request: makeRequest(maxTokens: 8, seed: 43),
            requestId: "req-b"))
        _ = await record(await bridge.submitTokenized(
            promptTokens: [1, 2, 4], request: makeRequest(maxTokens: 8, seed: 42),
            requestId: "req-c"))
        let ids = engine.submitted.map(\.id.raw)
        #expect(Set(ids).count == 3)
    }

    @Test("unseeded submissions keep fresh monotonic ids")
    func unseededStaysMonotonic() async {
        let engine = StochasticScriptedEngine()
        let bridge = makeBridge(engine: engine)
        _ = await record(await bridge.submitTokenized(
            promptTokens: [1, 2, 3], request: makeRequest(maxTokens: 8),
            requestId: "req-u1"))
        _ = await record(await bridge.submitTokenized(
            promptTokens: [1, 2, 3], request: makeRequest(maxTokens: 8),
            requestId: "req-u2"))
        #expect(engine.submitted[0].id == CBv2RequestID(1))
        #expect(engine.submitted[1].id == CBv2RequestID(2))
    }

    @Test("a live identical seeded request falls back to a fresh id (collision guard)")
    func liveCollisionFallsBackToFreshId() async {
        // Manual engine keeps the first submission LIVE while the identical
        // second one arrives.
        let engine = ScriptedCBv2Engine(script: .manual)
        let bridge = makeBridge(engine: engine)
        let first = await bridge.submitTokenized(
            promptTokens: [1, 2, 3], request: makeRequest(maxTokens: 8, seed: 42),
            requestId: "req-live-a")
        let second = await bridge.submitTokenized(
            promptTokens: [1, 2, 3], request: makeRequest(maxTokens: 8, seed: 42),
            requestId: "req-live-b")
        #expect(engine.submitted.count == 2)
        let firstId = engine.submitted[0].id
        let secondId = engine.submitted[1].id
        // First got the stable seeded id; the overlapping duplicate got a
        // fresh monotonic id (documented reproducibility waiver) — never a
        // duplicate live id inside the engine.
        #expect(firstId.raw & EngineV2Bridge.seededIdTagBit != 0)
        #expect(secondId.raw & EngineV2Bridge.seededIdTagBit == 0)
        #expect(firstId != secondId)
        withExtendedLifetime((first, second)) {}
    }

    @Test("stableSeededRawId is deterministic, tagged, and input-sensitive")
    func stableSeededRawIdProperties() {
        let a = EngineV2Bridge.stableSeededRawId(seed: 42, promptTokens: [1, 2, 3])
        let b = EngineV2Bridge.stableSeededRawId(seed: 42, promptTokens: [1, 2, 3])
        #expect(a == b)
        #expect(a & EngineV2Bridge.seededIdTagBit != 0)
        #expect(a != EngineV2Bridge.stableSeededRawId(seed: 43, promptTokens: [1, 2, 3]))
        #expect(a != EngineV2Bridge.stableSeededRawId(seed: 42, promptTokens: [1, 2]))
        #expect(a != EngineV2Bridge.stableSeededRawId(seed: 42, promptTokens: [1, 2, 4]))
        // Empty prompt still derives a valid tagged id.
        let empty = EngineV2Bridge.stableSeededRawId(seed: 42, promptTokens: [])
        #expect(empty & EngineV2Bridge.seededIdTagBit != 0)
    }
}
