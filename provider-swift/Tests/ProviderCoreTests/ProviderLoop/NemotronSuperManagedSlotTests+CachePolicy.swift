// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// A coordinator request whose sealed `cache_policy` is `memory_only` runs on
/// the managed Super slot with its prefix cache off, on the text and the
/// image route alike: it looks nothing up, restores nothing the owner's bank
/// holds and publishes nothing, while the same request unmarked uses the bank.
extension NemotronSuperManagedSlotTests {
    /// The prefix-cache outcome of each native terminal, in order.
    final class CacheOutcomes: @unchecked Sendable {
        private let lock = NSLock()
        private var outcomes: [CBv2PrefixCacheOutcome] = []
        func record(_ usage: CBv2Usage) { lock.withLock { outcomes.append(usage.prefixCacheOutcome) } }
        var all: [CBv2PrefixCacheOutcome] { lock.withLock { outcomes } }
    }

    static func markedMemoryOnly(_ body: Data) throws -> Data {
        var value = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        value["_darkbloom_cache"] = ["cache_policy": "memory_only"]
        return try JSONSerialization.data(withJSONObject: value)
    }

    @Test(.timeLimit(.minutes(3)))
    func memoryOnlyTextLeavesTheBankAlone() async throws {
        let fixture = try await Self.fixture(mode: .off,
            environment: [NemotronSuperLocalPrefill.chunkKey: "256", PrefixCachePolicy.memoryEnvironmentFlag: "1"],
            tokenizer: { SuperBytePromptTokenizer(script: $0) })
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let loop = fixture.loop, script = fixture.script
        try await loop.ensureModelLoaded(modelId: Self.modelID, allowEviction: false,
                                         revisionDirectory: fixture.directory)
        let owner = try #require(await loop.nemotronSuperOwnerForTesting(modelId: Self.modelID))
        #expect(owner.prefixBankBytes > 0)

        let question = String((0 ..< 560).map { index in
            Character(UnicodeScalar(UInt8(97 + (index * 7) % 26)))
        })
        func text() throws -> Data {
            try Self.body(["Sure", ", ", "here", "."], script: script,
                ["messages": [["role": "system", "content": "Be brief."], ["role": "user", "content": question]]])
        }
        let recorder = Recorder(), consumer = NodeKeyPair.generate()

        // Text: the unmarked request publishes its checkpoints to the bank;
        // the marked repeat makes no lookup and restores none of them.
        let primed = try await Self.send(text(), to: loop, recorder: recorder, consumer: consumer,
            cacheReceiptNonce: "text-default", prefixCacheProtocol: 2)
        let readyDeadline = ContinuousClock.now + .seconds(5)
        while Self.ready(recorder, nonce: "text-default") == nil, ContinuousClock.now < readyDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(Self.ready(recorder, nonce: "text-default")?.readyAnchors.isEmpty == false)
        let markedText = try await Self.send(Self.markedMemoryOnly(text()), to: loop, recorder: recorder,
            consumer: consumer, cacheReceiptNonce: "text-marked", prefixCacheProtocol: 2)
        let markedTextUsage = try #require(Self.usage(markedText.terminal))
        #expect(markedTextUsage.cachedTokens ?? 0 == 0 && markedTextUsage.cacheOutcome != .hit)
        #expect(Self.lookup(recorder, nonce: "text-marked") == nil)
        #expect(SuperSSE(markedText.sse).content == SuperSSE(primed.sse).content)

        try await Task.sleep(for: .milliseconds(200))
        #expect(Self.ready(recorder, nonce: "text-marked") == nil)
        #expect(await loop.unloadModel(Self.modelID))
        #expect(await fixture.budget.reservationBytesSnapshot().isEmpty)
    }

    @Test(.timeLimit(.minutes(3)))
    func memoryOnlyImagesLeaveTheBankAlone() async throws {
        let fixture = try await Self.fixture(mode: .off,
            environment: [NemotronSuperLocalPrefill.chunkKey: "256", PrefixCachePolicy.memoryEnvironmentFlag: "1"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let loop = fixture.loop, script = fixture.script
        try await loop.ensureModelLoaded(modelId: Self.modelID, allowEviction: false,
                                         revisionDirectory: fixture.directory)
        let owner = try #require(await loop.nemotronSuperOwnerForTesting(modelId: Self.modelID))
        #expect(owner.prefixBankBytes > 0)
        // The media route reports no cache outcome upstream; the engine's own
        // terminal usage shows each request's lookup (`.skippedPolicy`: the
        // request's cache was off).
        let outcomes = CacheOutcomes()
        await owner.bridge._testInstallPersistentTerminalGate { outcomes.record($0) }
        let recorder = Recorder(), consumer = NodeKeyPair.generate()
        let image = try Self.imageBody(["A", " cat", "."], script: script, maxTokens: 3)
        func send(_ body: Data, _ nonce: String) async throws -> (sse: String, terminal: OutboundMessage) {
            try await Self.send(body, to: loop, recorder: recorder, consumer: consumer,
                                cacheReceiptNonce: nonce, prefixCacheProtocol: 2)
        }
        // Unmarked, the image's prefix goes to the bank and its repeat restores it.
        let cold = try await send(image, "image-cold")
        let warm = try await send(image, "image-warm")
        #expect(outcomes.all == [.miss, .hit], "\(outcomes.all) \(cold.terminal) \(warm.terminal)")
        // Marked, the same request runs with its cache off: no lookup, no restore.
        let marked = try await send(Self.markedMemoryOnly(image), "image-marked")
        #expect(outcomes.all.count == 3 && outcomes.all.last == .skippedPolicy, "\(outcomes.all) \(marked.terminal)")
        #expect(Self.lookup(recorder, nonce: "image-marked") == nil)
        #expect(Self.ready(recorder, nonce: "image-marked") == nil)
        #expect(SuperSSE(marked.sse).content == SuperSSE(cold.sse).content)
        // The bank still serves the unmarked request.
        _ = try await send(image, "image-after")
        #expect(outcomes.all.count == 4 && outcomes.all.last == .hit, "\(outcomes.all)")
        await owner.bridge._testInstallPersistentTerminalGate(nil)
        #expect(await loop.unloadModel(Self.modelID))
        #expect(await fixture.budget.reservationBytesSnapshot().isEmpty)
    }
}
