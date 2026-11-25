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
