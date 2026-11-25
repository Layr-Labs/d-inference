import Foundation
import Testing

@testable import ProviderCore

@Suite("Blind request bounds")
struct BlindRequestBoundsTests {
    static func bounds(maxTokens: Int = 64, promptTokenBound: Int = 100) -> BlindRequestBounds {
        BlindRequestBounds(BlindServingTerms(maxTokens: maxTokens, promptTokenBound: promptTokenBound, cacheSalt: nil))
    }

    @Test("the first submission's prompt must fit the bound; a later one is not compared")
    func promptBound() {
        let within = Self.bounds()
        #expect(!within.wereApplied)
        #expect(within.admit(promptTokens: 100))
        #expect(within.wereApplied)
        #expect(within.admit(promptTokens: 10_000))
        #expect(!within.promptBoundExceeded)

        let over = Self.bounds()
        #expect(!over.admit(promptTokens: 101))
        #expect(over.promptBoundExceeded)
        #expect(over.wereApplied)
    }

    @Test("a submission generates at most the signed output bound")
    func outputBound() {
        let bounds = Self.bounds(maxTokens: 64)
        #expect(bounds.outputLimit(requested: nil) == 64)
        #expect(bounds.outputLimit(requested: 16) == 16)
        #expect(bounds.outputLimit(requested: 4_096) == 64)
    }

    @Test("every output budget the bridge sizes under a blind request's bounds is within the signed bound")
    func bridgeOutputBudgets() async {
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30)
        }
        let bridge = EngineV2Bridge(
            engine: PrefillScriptEngine(), modelId: "blind-bounds",
            tokenizer: TokenizerHandle(CancelledPrefixTokenizer(prompt: [1, 2, 3])), eosTokenIds: [],
            kvBytesPerToken: 4_000, kvBudget: budget)
        #expect(bridge.outputTokens(requested: 1_000, promptTokens: 3) == 1_000)
        BlindRequestBounds.$current.withValue(Self.bounds(maxTokens: 8)) {
            #expect(bridge.outputTokens(requested: nil, promptTokens: 3) == 8)
            #expect(bridge.outputTokens(requested: 4, promptTokens: 3) == 4)
            #expect(bridge.outputTokens(requested: 1_000, promptTokens: 3) == 8)
        }
        await bridge.shutdown()
    }

    @Test("the cache scope is the signed scope, narrowed by the client's salt")
    func cacheScope() {
        #expect(BlindBodyCheck.cacheScope(signed: nil, salt: Data(count: 16)) == nil)
        #expect(BlindBodyCheck.cacheScope(signed: "", salt: nil) == nil)
        #expect(BlindBodyCheck.cacheScope(signed: "account", salt: nil) == "account")
        let first = BlindBodyCheck.cacheScope(signed: "account", salt: Data(repeating: 1, count: 16))
        let second = BlindBodyCheck.cacheScope(signed: "account", salt: Data(repeating: 2, count: 16))
        #expect(first?.hasPrefix("account|s:") == true)
        #expect(first?.count == "account|s:".count + 22)
        #expect(first != second)
    }
}
