// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import Testing
@testable import ProviderCore

/// Gated full-checkpoint prefix reuse of the managed Super slot through the
/// production loader and the encrypted coordinator path. Loads about 80 GB;
/// run only with exclusive GPU access, `DARKBLOOM_SUPER_MANAGED_LIVE=1`,
/// `DARKBLOOM_SUPER_PREFIX_LIVE=1` and `NEMOTRON_SUPER_CHECKPOINT_DIR`.
/// `DARKBLOOM_SUPER_LIVE_MTP=off` serves the plain owner;
/// `DARKBLOOM_SUPER_PREFIX_OUT` receives the measurements as JSON.
extension NemotronSuperManagedSlotTests {
    /// One coordinator request with its first-content time.
    struct PrefixTimedAnswer {
        let sse: String
        let terminal: OutboundMessage
        let firstContentSeconds: Double
        var content: String { SuperSSE(sse).content }
    }

    /// `send`, also timing the first frame that carries content or reasoning.
    static func prefixTimedSend(_ body: Data, to loop: ProviderLoop, recorder: Recorder, consumer: NodeKeyPair,
                          scope: String?, nonce: String) async throws -> PrefixTimedAnswer {
        let started = ContinuousClock.now
        let first = Box<Double>()
        let answer = try await send(body, to: loop, recorder: recorder, consumer: consumer, scope: scope,
                                    deadline: 900, cacheReceiptNonce: nonce, prefixCacheProtocol: 2) { id in
            var seen = 0
            while ContinuousClock.now - started < .seconds(900) {
                let chunks = recorder.chunks(id)
                for payload in chunks.dropFirst(seen) {
                    let frame = (try? consumer.decryptPayload(payload)).map { String(decoding: $0, as: UTF8.self) } ?? ""
                    let parsed = SuperSSE(frame)
                    if !parsed.content.isEmpty || !parsed.reasoning.isEmpty {
                        let elapsed = started.duration(to: .now)
                        first.set(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
                        return
                    }
                }
                seen = chunks.count
                if recorder.terminal(id) != nil { return }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        return PrefixTimedAnswer(sse: answer.sse, terminal: answer.terminal, firstContentSeconds: first.value ?? -1)
    }

    static func liveDocument(facts count: Int) -> String {
        let colors = ["red", "green", "blue", "amber", "violet", "teal", "ochre", "silver"]
        return (1...count).map { item in
            "Fact \(item): item \(item) is \(colors[(item * 7) % colors.count]) and weighs \(item % 97) kg."
        }.joined(separator: " ")
    }

    static func liveBody(_ messages: [[String: String]], maxTokens: Int = 48) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model": modelID, "stream": true, "temperature": 0,
            "max_tokens": maxTokens, "chat_template_kwargs": ["enable_thinking": false], "messages": messages])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_SUPER_MANAGED_LIVE"] == "1"
        && ProcessInfo.processInfo.environment["DARKBLOOM_SUPER_PREFIX_LIVE"] == "1"
        && ProcessInfo.processInfo.environment["NEMOTRON_SUPER_CHECKPOINT_DIR"] != nil),
        .timeLimit(.minutes(30)))
    func pinnedCheckpointReusesPrefixesExactly() async throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: try #require(environment["NEMOTRON_SUPER_CHECKPOINT_DIR"]),
                            isDirectory: true)
        let (loop, loadSeconds) = try await Self.liveLoop(name: "super-prefix-live")
        let owner = try #require(await loop.nemotronSuperOwnerForTesting(modelId: Self.modelID))
        let speculates = environment["DARKBLOOM_SUPER_LIVE_MTP"] != "off"
        #expect(owner.speculates == speculates && owner.prefixBankBytes > 0)
        let capability = try #require(owner.bridge.residentPrefixCacheEvidence?.capability())
        let contract = try PromptContractIdentity.compute(modelDirectory: directory)
        #expect(capability.modelId == Self.modelID && capability.promptContractId == contract)
        if let expected = environment["DARKBLOOM_SUPER_EXPECTED_PROMPT_CONTRACT"] {
            #expect(contract == expected)
        }
        if let expected = environment["DARKBLOOM_SUPER_EXPECTED_AGGREGATE"] {
            #expect(capability.modelAggregateHash == expected)
        }
        let recorder = Recorder(), consumer = NodeKeyPair.generate()
        let facts = Int(environment["DARKBLOOM_SUPER_PREFIX_FACTS"] ?? "") ?? 420
        let document = Self.liveDocument(facts: facts)
        let question = "\n\nWhat color is item \(facts / 3), and how much does it weigh?"
        let repeated = try Self.liveBody([["role": "user", "content": document + question]])
        let mtpBefore = await owner.bridge.mtpStatusSnapshot()

        // Cold, then the identical request: a hit on the deepest whole chunk.
        let cold = try await Self.prefixTimedSend(repeated, to: loop, recorder: recorder, consumer: consumer,
                                            scope: "tenant-a", nonce: "cold")
        let coldUsage = try #require(Self.usage(cold.terminal), "\(cold.terminal)")
        let warm = try await Self.prefixTimedSend(repeated, to: loop, recorder: recorder, consumer: consumer,
                                            scope: "tenant-a", nonce: "warm")
        let warmUsage = try #require(Self.usage(warm.terminal), "\(warm.terminal)")
        let chunk = NemotronSuperLocalPrefill.defaultChunkTokens
        let deepest = (Int(coldUsage.promptTokens) - 1) / chunk * chunk
        #expect(coldUsage.cacheOutcome == .missAbsent && coldUsage.cachedTokens == 0)
        #expect(warmUsage.cacheOutcome == .hit && warmUsage.cacheTier == .memory)
        #expect(warmUsage.cachedTokens == UInt64(deepest) && warmUsage.prefillTokensSaved == UInt64(deepest))
        #expect(warm.sse.contains(#""cached_tokens":\#(deepest)"#))
        #expect(warm.content == cold.content, "a restore streams the cold text")
        let warmLookup = try #require(Self.lookup(recorder, nonce: "warm"))
        #expect(warmLookup.outcome == .hit && warmLookup.matchedAnchor?.tokenCount == UInt64(deepest))
        let ready = Self.ready(recorder, nonce: "cold")
        #expect(ready?.readyAnchors.last?.tokenCount == UInt64(deepest))

        // The next turn of the conversation reuses the shared prefix.
        let nextTurn = try Self.liveBody([["role": "user", "content": document + question],
            ["role": "assistant", "content": cold.content],
            ["role": "user", "content": "And item \(facts / 2)?"]])
        let next = try await Self.prefixTimedSend(nextTurn, to: loop, recorder: recorder, consumer: consumer,
                                            scope: "tenant-a", nonce: "next")
        let nextUsage = try #require(Self.usage(next.terminal), "\(next.terminal)")
        #expect(nextUsage.cacheOutcome == .hit && (nextUsage.cachedTokens ?? 0) >= UInt64(deepest))
        let nextCold = try await Self.prefixTimedSend(nextTurn, to: loop, recorder: recorder, consumer: consumer,
                                                scope: "tenant-c", nonce: "next-cold")
        #expect(Self.usage(nextCold.terminal)?.cachedTokens == 0)
        #expect(next.content == nextCold.content, "the continuation streams the cold text")

        // Another tenant's identical prompt misses and streams the cold text.
        let other = try await Self.prefixTimedSend(repeated, to: loop, recorder: recorder, consumer: consumer,
                                             scope: "tenant-b", nonce: "other")
        let otherUsage = try #require(Self.usage(other.terminal), "\(other.terminal)")
        #expect(otherUsage.cacheOutcome == .missAbsent && otherUsage.cachedTokens == 0)
        #expect(other.content == cold.content)

        // Concurrent repeats on both tenants: every one hits its own entries.
        let concurrent = try await withThrowingTaskGroup(of: (String, PrefixTimedAnswer).self) { group in
            for (index, scope) in ["tenant-a", "tenant-b", "tenant-a", "tenant-b"].enumerated() {
                group.addTask {
                    (scope, try await Self.prefixTimedSend(repeated, to: loop, recorder: recorder, consumer: consumer,
                                                    scope: scope, nonce: "concurrent-\(index)"))
                }
            }
            var answers: [(String, PrefixTimedAnswer)] = []
            for try await answer in group { answers.append(answer) }
            return answers
        }
        for (scope, answer) in concurrent {
            let usage = Self.usage(answer.terminal)
            #expect(usage?.cacheOutcome == .hit && usage?.cachedTokens == UInt64(deepest), "\(scope)")
            #expect(answer.content == cold.content, "\(scope)")
        }
        let mtpAfter = await owner.bridge.mtpStatusSnapshot()
        if speculates {
            #expect(mtpAfter.rounds > mtpBefore.rounds && mtpAfter.acceptedDraftTokens > mtpBefore.acceptedDraftTokens)
        }

        let summary: [String: Any] = [
            "speculates": speculates, "load_seconds": Double(loadSeconds.components.seconds),
            "model_id": capability.modelId, "model_aggregate_sha256": capability.modelAggregateHash,
            "prompt_contract_id": capability.promptContractId, "cache_epoch": capability.cacheEpoch,
            "prefix_bank_bytes": owner.prefixBankBytes, "prompt_tokens": coldUsage.promptTokens,
            "cached_tokens": warmUsage.cachedTokens ?? 0,
            "ttft_cold_s": cold.firstContentSeconds, "ttft_warm_s": warm.firstContentSeconds,
            "ttft_next_turn_warm_s": next.firstContentSeconds, "ttft_next_turn_cold_s": nextCold.firstContentSeconds,
            "next_turn_prompt_tokens": nextUsage.promptTokens, "next_turn_cached_tokens": nextUsage.cachedTokens ?? 0,
            "ttft_other_tenant_s": other.firstContentSeconds,
            "ttft_concurrent_s": concurrent.map(\.1.firstContentSeconds),
            "content_sha256": SHA256.hash(data: Data(cold.content.utf8)).map { String(format: "%02x", $0) }.joined(),
            "content": cold.content, "next_turn_content": next.content,
            "mtp_rounds": mtpAfter.rounds - mtpBefore.rounds,
            "mtp_accepted_draft_tokens": mtpAfter.acceptedDraftTokens - mtpBefore.acceptedDraftTokens,
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .prettyPrinted])
        print("SUPER_PREFIX_LIVE " + String(decoding: data, as: UTF8.self))
        if let output = environment["DARKBLOOM_SUPER_PREFIX_OUT"] {
            try data.write(to: URL(fileURLWithPath: output))
        }
        #expect(await loop.unloadModel(Self.modelID))
        #expect(await loop.nemotronSuperRetainedWeightBytesForTesting() == 0)
        try await Self.awaitMemoryReturn(loop)
    }
}
