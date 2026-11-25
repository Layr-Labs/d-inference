import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import MLXLMCommon
@testable import MLXVLM
import NIOCore
import Testing
@testable import ProviderCore

/// Admits every id of the tiny synthetic vocabulary and counts the tokens the
/// engine confirms through it: the row sampled under this constraint.
private final class SuperCountingConstraint: CBv2TokenConstraint, @unchecked Sendable {
    let mode = CBv2TokenConstraintMode.auto
    let initialState = 0
    let maxTokens: Int
    let fallbackTokenID = 31
    let promptTokens: Int
    private let lock = NSLock()
    private var steps = 0
    init(maxTokens: Int, promptTokens: Int) {
        self.maxTokens = maxTokens
        self.promptTokens = promptTokens
    }
    var confirmed: Int { lock.withLock { steps } }
    func allowedTokenIDs(state: Int, remainingTokens: Int) -> [Int] { remainingTokens > 0 ? Array(0..<32) : [] }
    func nextState(state: Int, tokenID: Int) -> Int? {
        lock.withLock { steps += 1 }
        return 0
    }
}

private final class SuperMadeConstraints: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [(media: Bool, constraint: SuperCountingConstraint)] = []
    func add(media: Bool, _ constraint: SuperCountingConstraint) { lock.withLock { made.append((media, constraint)) } }
    var all: [(media: Bool, constraint: SuperCountingConstraint)] { lock.withLock { made } }
    func reset() { lock.withLock { made = [] } }
}

extension NemotronSuperLocalHTTPTests {
    /// The hook's text and image routes both submit the request's call
    /// grammar, built from the prompt each submits (visual tokens included),
    /// sized to the output the bridge resolves for it; the engine samples the
    /// row under it.
    @Test(.timeLimit(.minutes(2))) func textAndImageRoutesSubmitTheirCallGrammar() async throws {
        let dimensions = NemotronRadioDimensions(width: 2, layers: 1, heads: 1,
            channels: 3, patch: 16, positionSide: 32, prefix: 1, mlpWidth: 3)
        let (installed, construction, residency) = try SuperInstalledFixture(radioDimensions: dimensions).make()
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-grammar-http",
            weightBytes: UInt64(installed.receipt.payloadBytes), minimumKVBytes: 2 << 30))
        let script = SuperOutputScript()
        let tokenizer = TokenizerHandle(SuperScriptedTokenizer(script: script))
        let owner = try await NemotronSuperLocalBridgeBuilder.make(installed: installed,
            tokenizer: tokenizer, eosTokenIDs: [31],
            sizing: .init(weightsBytes: installed.receipt.payloadBytes, fp16KVBytesPerToken: 64,
                maxContextLength: 1024, defaultMaxTokens: 16), kvBytesCapacity: 2 << 30,
            kvBudget: budget, loadLease: lease, construction: construction, environment: [:])
        let template = try #require(Data(base64Encoded: superImagePinnedTemplateBase64,
                                        options: .ignoreUnknownCharacters))
        let made = SuperMadeConstraints()
        let bridge = owner.bridge
        // The hook resolves the budget; this grammar only records it.
        let hook = try NemotronSuperLocalImageHTTP(owner: owner, templateBytes: template) { plan, _, tokens, maxTokens in
            let constraint = SuperCountingConstraint(maxTokens: maxTokens, promptTokens: tokens.count)
            made.add(media: plan.hasMedia, constraint)
            return constraint
        }
        let token = "synthetic-super-grammar"
        let app = makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: token), defaultMaxTokens: 16,
            acquire: { id in throw MultiModelBatchSchedulerEngineError.modelNotLoaded(id) },
            tokenizerProvider: { _ in .init(tokenizer: tokenizer, modelType: "nemotron_h_omni") },
            availableModels: { [] }, mtpSlots: { [] },
            modelTypeProvider: { _ in "nemotron_h_omni" }, nemotronSuperImageHTTP: hook)
        let headers: HTTPFields = [.contentType: "application/json", .authorization: "Bearer " + token]
        let png = NemotronSuperToolFixture.png
        @Sendable func weather() -> [String: Any] {
            ["type": "function", "function": ["name": "get_weather",
                "parameters": ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]]]]
        }
        let call = ["Use tool.", "</think>", "<tool_call>", "\n<function=get_weather>",
                    "\n<parameter=city>", "\nParis", "\n</parameter>", "\n</function>", "\n</tool_call>"]
        @Sendable func body(image: Bool, maxTokens: Int?) throws -> ByteBuffer {
            script.set(call)
            let text: [String: Any] = ["type": "text", "text": "Weather?"]
            var value: [String: Any] = ["model": NemotronSuperLocalBinding.modelID, "stream": false,
                "temperature": 0, "tools": [weather()],
                "messages": [["role": "user", "content": image
                    ? [text, ["type": "image_url", "image_url": ["url": png]]] as Any : "Weather?" as Any]]]
            if let maxTokens { value["max_tokens"] = maxTokens }
            return ByteBuffer(bytes: try JSONSerialization.data(withJSONObject: value))
        }
        try await app.test(.live) { client in
            // A `max_tokens` past the 1,024-token window: the bridge cuts it to fit after the prompt, and the grammar
            // carries the cut budget (the engine refuses any other).
            made.reset()
            let cutBody = try body(image: false, maxTokens: 2_000)
            // The script's pieces repeat in a long answer, so only the budget and the engine's acceptance are read.
            let cut = try await client.execute(uri: "/v1/chat/completions", method: .post,
                headers: headers, body: cutBody) { response in
                #expect(response.status == .ok)
                return String(buffer: response.body)
            }
            #expect(cut.contains(#""completion_tokens""#) && !cut.contains(#""error""#))
            #expect(made.all.map { $0.constraint.maxTokens } == [1_024 - 3])
            for image in [false, true] {
                // With `max_tokens` the answer stops at the call's last piece;
                // without, the bridge's default (16) is the grammar's budget.
                for maxTokens in [call.count, nil] as [Int?] {
                    made.reset()
                    let text = try await client.execute(uri: "/v1/chat/completions", method: .post,
                        headers: headers, body: try body(image: image, maxTokens: maxTokens)) { response in
                        #expect(response.status == .ok, "image \(image)")
                        return String(buffer: response.body)
                    }
                    let names = try SuperJSON(text).toolCalls.map { $0.name }
                    #expect(names == ["get_weather"], "image \(image)")
                    let submitted = made.all
                    #expect(submitted.count == 1 && submitted.first?.media == image, "image \(image)")
                    let constraint = try #require(submitted.first?.constraint)
                    #expect(constraint.maxTokens == (maxTokens ?? 16), "image \(image)")
                    // An image prompt carries its visual tokens.
                    #expect(image ? constraint.promptTokens > 3 : constraint.promptTokens == 3, "image \(image)")
                    #expect(constraint.confirmed >= (maxTokens ?? 1), "image \(image)")
                }
            }
        }
        await hook.drain()
        try await owner.closeAfterDrain()
        #expect(residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }
}
