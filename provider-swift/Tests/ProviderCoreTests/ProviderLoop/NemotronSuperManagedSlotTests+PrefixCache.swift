// Copyright © 2026 Eigen Labs.

import Foundation
import Jinja
import MLXLMCommon
import Testing
@testable import ProviderCore

/// One prompt token per rendered byte (never the image placeholder 18), so a
/// prompt of a few hundred characters spans several 256-token blocks and a
/// repeated request repeats its tokens exactly.
struct SuperBytePromptTokenizer: MLXLMCommon.Tokenizer {
    let script: SuperOutputScript
    static func tokens(_ text: String) -> [Int] {
        text.utf8.map { byte in
            let token = Int(byte) % 61 + 1
            return token == 18 ? 19 : token
        }
    }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { Self.tokens(text) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { script.decode(count: tokenIds.count) }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        throw MLXLMCommon.TokenizerError.missingChatTemplate
    }
    func applyChatTemplate(messages: [[String: any Sendable]], chatTemplate: String,
                           tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
        let template = try Template(normalizeSwiftJinjaTemplate(chatTemplate),
                                    with: .init(lstripBlocks: true, trimBlocks: true))
        var context: [String: Value] = ["messages": .array(try messages.map { try Value(any: $0) }),
                                        "add_generation_prompt": true]
        for (key, value) in additionalContext ?? [:] { context[key] = try Value(any: value) }
        let prompt = try template.render(context)
        script.record(prompt)
        return Self.tokens(prompt)
    }
}

extension NemotronSuperManagedSlotTests {
    /// A coordinator request on the managed slot reports what its bank
    /// reused, on the plain and on the speculating owner. The slot
    /// advertises the published aggregate; a repeated prompt's lookup
    /// receipt hits the deepest 256-token chunk checkpoint the first request
    /// published, its terminal usage bills those cached tokens and its SSE
    /// usage names them, and its text equals the cold request's. Another
    /// tenant's identical prompt is cold and reports no reuse.
    @Test(.timeLimit(.minutes(3)), arguments: [MTPMode.off, .auto])
    func coordinatorRequestsReportTheBanksReuse(mode: MTPMode) async throws {
        let fixture = try await Self.fixture(mode: mode,
            environment: [NemotronSuperLocalPrefill.chunkKey: "256"],
            tokenizer: { SuperBytePromptTokenizer(script: $0) })
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let loop = fixture.loop, script = fixture.script
        try await loop.ensureModelLoaded(modelId: Self.modelID, allowEviction: false,
                                         revisionDirectory: fixture.directory)
        let owner = try #require(await loop.nemotronSuperOwnerForTesting(modelId: Self.modelID))
        #expect(owner.speculates == (mode == .auto) && owner.prefixBankBytes > 0)
        let capability = try #require(owner.bridge.residentPrefixCacheEvidence?.capability())
        #expect(capability.modelId == Self.modelID)
        #expect(capability.promptContractId == Self.fixturePromptContractID)
        #expect(capability.modelAggregateHash.count == 64)

        // About 600 rendered bytes: checkpoints at 256 and 512.
        let question = String((0 ..< 560).map { index in
            Character(UnicodeScalar(UInt8(97 + (index * 7) % 26)))
        })
        let pieces = ["Sure", ", ", "here", "."]
        func body() throws -> Data {
            try Self.body(pieces, script: script,
                ["messages": [["role": "system", "content": "Be brief."], ["role": "user", "content": question]]])
        }
        let recorder = Recorder(), consumer = NodeKeyPair.generate()
        let first = try await Self.send(body(), to: loop, recorder: recorder, consumer: consumer,
            cacheReceiptNonce: "nonce-first", prefixCacheProtocol: 2)
        let promptTokens = SuperBytePromptTokenizer.tokens(script.prompt).count
        #expect(promptTokens > 512 && promptTokens < 768, "\(promptTokens)")
        let firstUsage = try #require(Self.usage(first.terminal))
        #expect(firstUsage.cacheOutcome == .missAbsent && firstUsage.cacheTier == .memory)
        #expect(firstUsage.cachedTokens == 0)
        // The donor publishes its checkpoints before its terminal.
        let readyDeadline = ContinuousClock.now + .seconds(5)
        while Self.ready(recorder, nonce: "nonce-first") == nil, ContinuousClock.now < readyDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let ready = try #require(Self.ready(recorder, nonce: "nonce-first"))
        #expect(ready.tier == .memory && ready.readyAnchors.map(\.tokenCount) == [256, 512])
        #expect(ready.modelAggregateHash == capability.modelAggregateHash)

        let second = try await Self.send(body(), to: loop, recorder: recorder, consumer: consumer,
            cacheReceiptNonce: "nonce-second", prefixCacheProtocol: 2)
        let secondUsage = try #require(Self.usage(second.terminal))
        #expect(secondUsage.cacheOutcome == .hit && secondUsage.cacheTier == .memory)
        #expect(secondUsage.cachedTokens == 512 && secondUsage.prefillTokensSaved == 512)
        #expect(second.sse.contains(#""cached_tokens":512"#))
        let hit = try #require(Self.lookup(recorder, nonce: "nonce-second"))
        #expect(hit.outcome == .hit && hit.tier == .memory)
        #expect(hit.matchedAnchor == ready.readyAnchors.last)
        #expect(hit.expectedPrefillTokensSaved == 512 && hit.cacheEpoch == capability.cacheEpoch)
        #expect(SuperSSE(second.sse).content == SuperSSE(first.sse).content)

        let other = try await Self.send(body(), to: loop, recorder: recorder, consumer: consumer,
            scope: "tenant-b", cacheReceiptNonce: "nonce-other", prefixCacheProtocol: 2)
        let otherUsage = try #require(Self.usage(other.terminal))
        #expect(otherUsage.cacheOutcome == .missAbsent && otherUsage.cachedTokens == 0)
        #expect(other.sse.contains(#""cached_tokens":0"#) && !other.sse.contains(#""cached_tokens":512"#))
        #expect(Self.lookup(recorder, nonce: "nonce-other")?.matchedAnchor == nil)
        #expect(SuperSSE(other.sse).content == SuperSSE(first.sse).content)

        #expect(await loop.unloadModel(Self.modelID))
        #expect(await fixture.budget.reservationBytesSnapshot().isEmpty)
    }

    static func lookup(_ recorder: Recorder, nonce: String) -> ProviderMessage.PrefixCacheLookupV2? {
        recorder.snapshot.lazy.compactMap { message -> ProviderMessage.PrefixCacheLookupV2? in
            if case .prefixCacheLookupV2(let receipt) = message, receipt.cacheReceiptNonce == nonce { return receipt }
            return nil
        }.first
    }

    static func ready(_ recorder: Recorder, nonce: String) -> ProviderMessage.PrefixCacheReadyV2? {
        recorder.snapshot.lazy.compactMap { message -> ProviderMessage.PrefixCacheReadyV2? in
            if case .prefixCacheReadyV2(let receipt) = message, receipt.cacheReceiptNonce == nonce { return receipt }
            return nil
        }.first
    }
}
