// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("SSD prefix cache: HMAC lookup keys")
struct SSDLookupKeysTests {

    @Test("same input, different install key ⇒ different tag (T-041 leak #2 closed)")
    func keyedTags() {
        let hash = Data(SHA256.hash(data: Data("prefix".utf8)))
        let a = SSDLookupKeys(kek: SymmetricKey(size: .bits256))
        let b = SSDLookupKeys(kek: SymmetricKey(size: .bits256))
        #expect(a.tag(chainHash: hash, cacheSalt: "") != b.tag(chainHash: hash, cacheSalt: ""))
        // Deterministic under one key.
        #expect(a.tag(chainHash: hash, cacheSalt: "") == a.tag(chainHash: hash, cacheSalt: ""))
        #expect(a.tag(chainHash: hash, cacheSalt: "").count == 32)
        #expect(a.tag16(chainHash: hash, cacheSalt: "").count == 16)
    }

    @Test("salt scoping: different scopes can never share a tag; empty salt is length-prefixed")
    func saltScopedTags() {
        let keys = SSDLookupKeys(kek: SymmetricKey(size: .bits256))
        let hash = Data(SHA256.hash(data: Data("prefix".utf8)))
        let unscoped = keys.tag(chainHash: hash, cacheSalt: "")
        let scopeA = keys.tag(chainHash: hash, cacheSalt: "scope-a")
        let scopeB = keys.tag(chainHash: hash, cacheSalt: "scope-b")
        #expect(unscoped != scopeA)
        #expect(scopeA != scopeB)
        #expect(unscoped != scopeB)
        // Length-prefix unambiguity: salt "ab" ‖ hash H must not collide
        // with salt "a" ‖ ("b" prepended to H).
        let shifted = keys.tag(chainHash: Data("b".utf8) + hash, cacheSalt: "a")
        let joined = keys.tag(chainHash: hash, cacheSalt: "ab")
        #expect(shifted != joined)
    }
}
