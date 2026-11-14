// Copyright © 2026 Eigen Labs.
import Foundation
import Hummingbird
import HummingbirdTesting
import MLXLMCommon
import MLXLMServer
import NIOCore
import Testing
@testable import ProviderCore

/// Debug-only per-request MTP receipts: off unless the variable is `1`, counts
/// and engine timing only, and served only by a local API without a key.
@Suite("Debug MTP request receipts")
struct MTPRequestReceiptTests {
    @Test func onlyTheDebugVariableEnablesThem() {
        let key = MTPRequestReceiptRing.environmentKey
        #expect(key == "DARKBLOOM_DEBUG_MTP_RECEIPTS")
        for value in [nil, "", "0", "true", "yes", "2"] as [String?] {
            let environment = value.map { [key: $0] } ?? [:]
            #expect(!MTPRequestReceiptRing.enabled(environment: environment), "\(value ?? "unset")")
            #expect(MTPRequestReceiptRing.fromEnvironment(environment).capacity == 0)
        }
        for value in ["1", " 1\n"] {
            #expect(MTPRequestReceiptRing.enabled(environment: [key: value]))
            #expect(MTPRequestReceiptRing.fromEnvironment([key: value]).capacity
                == MTPRequestReceiptRing.defaultCapacity)
        }
    }

    @Test func theRingKeepsTheLatestCountsAndNoText() throws {
        var off = MTPRequestReceiptRing(capacity: 0)
        off.record(model: "m", usage: Self.usage(rounds: 3), promptTokens: 9, completionTokens: 4,
                   finishReason: .stop)
        #expect(off.receipts.isEmpty)

        var ring = MTPRequestReceiptRing(capacity: 2)
        ring.record(model: "m", usage: Self.usage(rounds: 1), promptTokens: 9, completionTokens: 4,
                    finishReason: .stop)
        ring.record(model: "m", usage: Self.usage(rounds: 2), promptTokens: 9, completionTokens: 5,
                    finishReason: .length)
        ring.record(model: "m", usage: Self.usage(rounds: 3), promptTokens: 9, completionTokens: 6,
                    finishReason: .error("secret-looking engine text"))
        #expect(ring.receipts.map(\.sequence) == [2, 3])
        let last = try #require(ring.receipts.last)
        #expect(last.mtpRounds == 3 && last.mtpProposed == 21 && last.mtpAccepted == 7)
        #expect(last.decodeSteps == 3 && last.batchRowsMin == 1 && last.batchRowsMax == 2 && last.batchRowsSum == 5)
        #expect(last.promptTokens == 9 && last.completionTokens == 6 && last.prefixCacheMatchedTokens == 4)
        #expect(last.finishReason == "error")
        #expect(last.firstTokenMs == 12.5 && last.lastTokenMs == 40 && last.finishedMs == nil)
        let json = String(decoding: try JSONEncoder().encode(MTPRequestReceiptList(data: ring.receipts)), as: UTF8.self)
        #expect(!json.contains("secret-looking"))
        #expect(json.contains("\"mtp_accepted\":7") && json.contains("\"object\":\"list\""))
    }

    @Test func aBridgeRecordsFinishedRequestsOnlyWhenEnabled() async throws {
        #expect(ProcessInfo.processInfo.environment[MTPRequestReceiptRing.environmentKey] == nil)
        let tokenizer = TokenizerHandle(ReceiptTokenizer())
        let bridge = EngineV2Bridge(engine: ReceiptEngine(), modelId: "receipts", tokenizer: tokenizer, eosTokenIds: [])
        let entry = MultiModelBatchSchedulerEngine.ModelRegistryEntry(tokenizer: tokenizer, engineV2Bridge: bridge)
        let service = MLXOpenAIService(engine: MultiModelBatchSchedulerEngine(registryProvider: { ["receipts": entry] }))
        let request = OpenAIChatCompletionRequest(model: "receipts", messages: [.init(role: .user, content: .text("hi"))])
        _ = try await service.createChatCompletion(request: request)
        #expect(await bridge.mtpRequestReceiptsSnapshot().isEmpty)

        await bridge.enableMTPRequestReceiptsForTesting()
        let response = try await service.createChatCompletion(request: request)
        #expect(response.choices.first?.message.content == .text("OK"))
        let receipts = await bridge.mtpRequestReceiptsSnapshot()
        #expect(receipts.count == 1)
        #expect(receipts.first?.model == "receipts" && receipts.first?.sequence == 1)
        #expect(receipts.first?.mtpRounds == 2 && receipts.first?.mtpProposed == 14 && receipts.first?.mtpAccepted == 5)
        #expect(receipts.first?.completionTokens == 1 && receipts.first?.finishReason == "stop")
        await bridge.shutdown()
    }

    @Test func onlyAnAPIWithoutAKeyServesThem() async throws {
        let fixture = MTPRequestReceiptList(data: {
            var ring = MTPRequestReceiptRing(capacity: 4)
            ring.record(model: "m", usage: Self.usage(rounds: 2), promptTokens: 3, completionTokens: 8,
                        finishReason: .stop)
            return ring.receipts
        }())
        func app(token: String?, receipts: Bool) -> LocalInferenceApplication {
            let rows = fixture.data
            let source: (@Sendable () async -> [MTPRequestReceipt])? = receipts ? { @Sendable in rows } : nil
            return makeLocalInferenceApplication(
                config: .init(host: "127.0.0.1", port: 0, authToken: token), defaultMaxTokens: 32,
                acquire: { throw MultiModelBatchSchedulerEngineError.modelNotLoaded($0) },
                tokenizerProvider: { _ in throw MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization },
                availableModels: { [] }, mtpSlots: { [] },
                mtpRequestReceipts: source)
        }
        try await app(token: nil, receipts: true).test(.router) { client in
            try await client.execute(uri: "/v1/debug/mtp-receipts", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.cacheControl] == "no-store")
                let decoded = try JSONDecoder().decode(
                    MTPRequestReceiptList.self, from: Data(String(buffer: response.body).utf8))
                #expect(decoded == fixture)
            }
        }
        try await app(token: nil, receipts: false).test(.router) { client in
            try await client.execute(uri: "/v1/debug/mtp-receipts", method: .get) { response in
                #expect(response.status == .notFound)
            }
        }
        try await app(token: "synthetic-fixture-token", receipts: true).test(.router) { client in
            try await client.execute(uri: "/v1/debug/mtp-receipts", method: .get,
                                     headers: [.authorization: "Bearer synthetic-fixture-token"]) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    static func usage(rounds: UInt32) -> CBv2Usage {
        var usage = CBv2Usage(promptTokens: 9, completionTokens: 4, prefixCacheMatchedTokens: 4)
        var t = CBv2RequestTiming()
        t.mtpRounds = rounds
        t.mtpProposed = 7 * rounds
        t.mtpAccepted = rounds + rounds / 2 + (rounds == 3 ? 3 : 0)
        t.decodeSteps = rounds
        t.batchRowsMin = 1
        t.batchRowsMax = 2
        t.batchRowsSum = 5
        t.firstTokenNanos = 12_500_000
        t.lastTokenNanos = 40_000_000
        usage.timing = t
        return usage
    }
}

private final class ReceiptEngine: CBv2Engine {
    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        AsyncStream { continuation in
            continuation.yield(.delta(text: "OK", tokens: [9], logprobs: nil))
            var usage = CBv2Usage(promptTokens: 3, completionTokens: 1)
            var t = CBv2RequestTiming()
            t.mtpRounds = 2
            t.mtpProposed = 14
            t.mtpAccepted = 5
            usage.timing = t
            continuation.yield(.finished(reason: .stop, usage: usage))
            continuation.finish()
        }
    }
    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }
    func shutdown() async {}
}

private struct ReceiptTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1, 2, 3] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "OK" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] { [1, 2, 3] }
}
