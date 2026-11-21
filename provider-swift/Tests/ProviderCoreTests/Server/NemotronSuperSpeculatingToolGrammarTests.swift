import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import MLXLMCommon
@testable import MLXVLM
import NIOCore
import Testing
@testable import ProviderCore

/// Spells every generated token id as its own character, so an answer shows
/// the exact ids; the template renders `[1, 18, 2]` for a message with an
/// image part and `[1, 2, 3]` otherwise.
private struct SuperIDTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1, 2, 3] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        String(String.UnicodeScalarView(tokenIds.compactMap { Unicode.Scalar(0x4E00 + $0) }))
    }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { "x" }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        "\(messages)".contains("image_url") ? [1, 18, 2] : [1, 2, 3]
    }
    func applyChatTemplate(messages: [[String: any Sendable]], chatTemplate: String,
                           tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
        try applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}

/// Admits every id of the synthetic vocabulary, so a row under it decodes the
/// same greedy tokens as a free one, and counts the tokens confirmed through it.
private final class SuperOpenConstraint: CBv2TokenConstraint, @unchecked Sendable {
    let mode = CBv2TokenConstraintMode.auto
    let initialState = 0
    let maxTokens: Int
    let fallbackTokenID = SuperMTPInstalledFixture.vocabulary - 1
    private let lock = NSLock()
    private var steps = 0
    init(maxTokens: Int) { self.maxTokens = maxTokens }
    var confirmed: Int { lock.withLock { steps } }
    func allowedTokenIDs(state: Int, remainingTokens: Int) -> [Int] {
        remainingTokens > 0 ? Array(0..<SuperMTPInstalledFixture.vocabulary) : []
    }
    func nextState(state: Int, tokenID: Int) -> Int? {
        lock.withLock { steps += 1 }
        return 0
    }
}

/// A free span (state 0, as the call grammar's reasoning and text) until one
/// boundary id, then a protected state that admits every id: the real
/// grammar's hand-over from its spans to a call, over the whole vocabulary.
private final class SuperSpanConstraint: CBv2FreeSpanTokenConstraint, @unchecked Sendable {
    let mode = CBv2TokenConstraintMode.auto
    let initialState = 0
    let maxTokens: Int
    let fallbackTokenID = SuperMTPInstalledFixture.vocabulary - 1
    let boundary: Int
    private let lock = NSLock()
    private var steps = 0
    private var crossed = false
    private var spanReads = 0
    private var continuations = 0
    init(maxTokens: Int, boundary: Int) {
        self.maxTokens = maxTokens
        self.boundary = boundary
    }
    var confirmed: Int { lock.withLock { steps } }
    var crossedBoundary: Bool { lock.withLock { crossed } }
    /// The engine read the committed state as a free span, and previewed drafts as its continuations.
    var spanUse: (reads: Int, continuations: Int) { lock.withLock { (spanReads, continuations) } }
    func allowedTokenIDs(state: Int, remainingTokens: Int) -> [Int] {
        remainingTokens > 0 ? Array(0..<SuperMTPInstalledFixture.vocabulary) : []
    }
    func nextState(state: Int, tokenID: Int) -> Int? {
        lock.withLock {
            steps += 1
            if state == 0, tokenID == boundary { crossed = true; return 1 }
            return state
        }
    }
    func isFreeSpan(state: Int) -> Bool {
        lock.withLock { if state == 0 { spanReads += 1 } }
        return state == 0
    }
    func isFreeSpanContinuation(state: Int, tokenID: Int) -> Bool {
        let continues = state == 0 && tokenID != boundary && tokenID != fallbackTokenID
            && (0..<SuperMTPInstalledFixture.vocabulary).contains(tokenID)
        if continues { lock.withLock { continuations += 1 } }
        return continues
    }
}

private final class SuperRowOverlap: @unchecked Sendable {
    private let lock = NSLock()
    private var maximum = 0
    func observe(_ rows: Int) { lock.withLock { maximum = max(maximum, rows) } }
    var most: Int { lock.withLock { maximum } }
}

private final class SuperOpenConstraints: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [SuperOpenConstraint] = []
    private var boundary: Int?
    private var spans: [SuperSpanConstraint] = []
    /// The next request that declares the `span` tool gets a span constraint ending at this id.
    var spanBoundary: Int? {
        get { lock.withLock { boundary } }
        set { lock.withLock { boundary = newValue } }
    }
    func add(_ constraint: SuperSpanConstraint) { lock.withLock { spans.append(constraint) } }
    var spanConstraints: [SuperSpanConstraint] { lock.withLock { spans } }
    func add(_ constraint: SuperOpenConstraint) { lock.withLock { made.append(constraint) } }
    var all: [SuperOpenConstraint] { lock.withLock { made } }
}

extension NemotronSuperLocalHTTPTests {
    /// On a speculating owner a constrained text row drafts too, with
    /// grammar-aware verification (`NemotronSuperLocalMTP.config`'s default),
    /// and answers the free row's exact greedy tokens, alone and beside a free
    /// row in the same steps. A constrained image row runs target-only, as
    /// every image row does there.
    @Test(.timeLimit(.minutes(3))) func aSpeculatingOwnerDecodesConstrainedRowsBesideDraftingOnes() async throws {
        let fixture = try SuperMTPInstalledFixture(
            radioDimensions: SuperMTPInstalledFixture.encodedImageTower).make()
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 16 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let bytes = fixture.installed.receipt.payloadBytes
            + (try NemotronSuperLocalMTP.loadSupplementBytes(fixture.headQuote))
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-grammar-mtp",
            weightBytes: UInt64(bytes), minimumKVBytes: 2 << 30))
        let tokenizer = TokenizerHandle(SuperIDTokenizer())
        let owner = try await NemotronSuperLocalBridgeBuilder.make(installed: fixture.installed,
            tokenizer: tokenizer, eosTokenIDs: [SuperMTPInstalledFixture.vocabulary - 1],
            sizing: .init(weightsBytes: fixture.installed.receipt.payloadBytes,
                fp16KVBytesPerToken: 64, maxContextLength: 1024, defaultMaxTokens: 8),
            kvBytesCapacity: 2 << 30, kvBudget: budget, loadLease: lease,
            construction: fixture.construction,
            mtp: .init(module: fixture.head, setting: .init(depth: 1)),
            environment: [NemotronSuperLocalBridgeBuilder.maxConcurrentKey: "3"])
        #expect(owner.speculates)
        let template = try #require(Data(base64Encoded: superImagePinnedTemplateBase64,
                                        options: .ignoreUnknownCharacters))
        let made = SuperOpenConstraints()
        // Requests that declare tools are constrained; the others are free.
        let hook = try NemotronSuperLocalImageHTTP(owner: owner, templateBytes: template) { plan, _, _, maxTokens in
            guard let tools = plan.toolPolicy.tools, !tools.isEmpty else { return nil }
            if tools[0].function.name == "span", let boundary = made.spanBoundary {
                let constraint = SuperSpanConstraint(maxTokens: maxTokens, boundary: boundary)
                made.add(constraint)
                return constraint
            }
            let constraint = SuperOpenConstraint(maxTokens: maxTokens)
            made.add(constraint)
            return constraint
        }
        let token = "synthetic-super-grammar-mtp"
        let app = makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: token), defaultMaxTokens: 8,
            acquire: { id in throw MultiModelBatchSchedulerEngineError.modelNotLoaded(id) },
            tokenizerProvider: { _ in .init(tokenizer: tokenizer, modelType: "nemotron_h_omni") },
            availableModels: { [] }, mtpSlots: { [] },
            modelTypeProvider: { _ in "nemotron_h_omni" }, nemotronSuperImageHTTP: hook)
        let headers: HTTPFields = [.contentType: "application/json", .authorization: "Bearer " + token]
        let rounds: @Sendable () async -> Int? = {
            let engine = await owner.bridge.ownedEngine
            return (engine as? EngineV2)?.mtpMetricsSnapshot()?.rounds
        }
        @Sendable func body(tools: Bool, image: Bool = false, maxTokens: Int = 8, tool: String = "noop") throws -> ByteBuffer {
            let content: Any = image
                ? [["type": "text", "text": "fixture"],
                   ["type": "image_url", "image_url": ["url": NemotronSuperToolFixture.png]]] as Any
                : "fixture" as Any
            var value: [String: Any] = ["model": NemotronSuperLocalBinding.modelID, "stream": false,
                "max_tokens": maxTokens, "temperature": 0, "enable_thinking": false,
                "messages": [["role": "user", "content": content]]]
            if tools {
                value["tools"] = [["type": "function", "function": ["name": tool,
                    "parameters": ["type": "object", "properties": [String: Any]()]]]]
            }
            return ByteBuffer(bytes: try JSONSerialization.data(withJSONObject: value))
        }
        @Sendable func content(_ status: HTTPResponse.Status, _ body: ByteBuffer) throws -> String {
            #expect(status == .ok)
            return try SuperJSON(String(buffer: body)).content ?? ""
        }
        try await app.test(.live) { client in
            func send(_ buffer: ByteBuffer) async throws -> String {
                let response = try await client.execute(uri: "/v1/chat/completions", method: .post,
                                                        headers: headers, body: buffer)
                return try content(response.status, response.body)
            }
            let start = try #require(await rounds())
            let free = try await send(body(tools: false))
            #expect(!free.isEmpty)
            let afterFree = try #require(await rounds())
            #expect(afterFree > start, "a free row drafts")
            // Alone, the constrained row drafts under the grammar and answers the same tokens.
            #expect(try await send(body(tools: true)) == free)
            let afterConstrained = try #require(await rounds())
            #expect(afterConstrained > afterFree, "a constrained row drafts")
            // Through a free span (drafts scored on the span's masked window and accepted as same-state
            // continuations) to a boundary id late in a longer answer, then the grammar path: still the free row's
            // exact tokens.
            let longFree = try await send(body(tools: false, maxTokens: 32))
            let ids = longFree.unicodeScalars.map { Int($0.value) - 0x4E00 }
            try #require(ids.count >= 8, "a long enough greedy answer")
            made.spanBoundary = ids[ids.count * 3 / 4]
            let beforeSpan = try #require(await rounds())
            #expect(try await send(body(tools: true, maxTokens: 32, tool: "span")) == longFree)
            let span = try #require(made.spanConstraints.first)
            #expect(span.crossedBoundary && span.confirmed >= ids.count)
            #expect(span.spanUse.reads > 0 && span.spanUse.continuations > 0, "the span path ran")
            let afterSpan = try #require(await rounds())
            #expect(afterSpan > beforeSpan, "a row in a free span drafts")
            #expect(made.all.count == 1 && made.all[0].confirmed >= free.unicodeScalars.count)
            // Beside each other: a longer constrained answer and a free one decode in the same steps (the engine
            // holds both rows at once); the free row keeps drafting, and both answer the free row's tokens.
            let constrainedBody = try body(tools: true, maxTokens: 64), freeBody = try body(tools: false)
            let overlap = SuperRowOverlap()
            let watcher = Task {
                while !Task.isCancelled {
                    overlap.observe(await owner.bridge.capacitySnapshot().activeRequests)
                    try? await Task.sleep(for: .microseconds(200))
                }
            }
            // Two connections: the test client sends its requests one at a time on one.
            let port = try #require(client.port)
            @Sendable func post(_ buffer: ByteBuffer) async throws -> String {
                var request = URLRequest(url: URL(string: "http://localhost:\(port)/v1/chat/completions")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                request.httpBody = Data(buffer: buffer)
                let session = URLSession(configuration: .ephemeral)
                defer { session.finishTasksAndInvalidate() }
                let (data, response) = try await session.data(for: request)
                return try content(.init(code: (response as? HTTPURLResponse)?.statusCode ?? 0),
                                   ByteBuffer(bytes: data))
            }
            async let constrained = post(constrainedBody)
            async let other = post(freeBody)
            let (long, short) = try await (constrained, other)
            watcher.cancel()
            #expect(overlap.most == 2, "both rows were in the engine at once")
            #expect(long.hasPrefix(free) && short == free)
            #expect(try #require(await rounds()) > afterSpan, "the rows draft beside each other")
            #expect(made.all.count == 2 && made.all[1].confirmed >= long.unicodeScalars.count)
            // An image row with a grammar runs target-only and completes.
            let beforeImage = await rounds()
            let imageAnswer = try await send(body(tools: true, image: true))
            #expect(!imageAnswer.isEmpty)
            #expect(await rounds() == beforeImage)
            #expect(made.all.count == 3 && made.all[2].confirmed > 0)
        }
        await hook.drain()
        try await owner.closeAfterDrain()
        #expect(fixture.residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }
}
