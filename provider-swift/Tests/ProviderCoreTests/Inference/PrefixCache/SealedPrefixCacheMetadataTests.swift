import Foundation
import Testing

@testable import ProviderCore

@Suite("Sealed copy of the prefix-cache identity")
struct SealedPrefixCacheMetadataTests {
    private func sealed(_ body: String) -> SealedPrefixCacheMetadata? {
        InboundChatExtensions(from: Data(body.utf8)).sealedPrefixCache
    }

    @Test("the body's _darkbloom_cache member decodes; a missing, blank or malformed one is nil")
    func decodesTheBodyMember() {
        let body = #"""
            {"model":"m","messages":[{"role":"user","content":"hi"}],
             "_darkbloom_cache":{"nonce":"n-1","scope":"sealed-scope","repeated_prefix_tokens":2048}}
            """#
        #expect(
            sealed(body)
                == SealedPrefixCacheMetadata(
                    receiptNonce: "n-1", scope: "sealed-scope", repeatedPrefixTokens: 2048))
        #expect(sealed(#"{"model":"m","messages":[]}"#) == nil)
        #expect(sealed(#"{"_darkbloom_cache":{"nonce":" ","scope":"s"}}"#) == nil)
        #expect(sealed(#"{"_darkbloom_cache":{"nonce":"n","scope":""}}"#) == nil)
        #expect(sealed(#"{"_darkbloom_cache":"s"}"#) == nil)
        #expect(sealed(#"{"_darkbloom_cache":{"nonce":"n","scope":"s"}}"#)?.repeatedPrefixTokens == nil)
        #expect(
            sealed(#"{"_darkbloom_cache":{"nonce":"n","scope":"s","repeated_prefix_tokens":-4}}"#)?
                .repeatedPrefixTokens == 0)
    }

    @Test("the member leaves the request and its other extensions as they were")
    func otherFieldsUnchanged() throws {
        let body = Data(
            #"""
            {"model":"m","messages":[{"role":"user","content":"hi"}],"seed":7,
             "_darkbloom_cache":{"nonce":"n","scope":"s"}}
            """#.utf8)
        let inbound = try ProviderLoop.decodeInboundChatRequest(body)
        #expect(inbound.request.messages.count == 1)
        #expect(inbound.extensions.samplingOverrides?.seed == 7)
        #expect(inbound.extensions.sealedPrefixCache?.scope == "s")
    }

    @Test("a copy with this attempt's receipt nonce replaces the frame's scope and repeat demand")
    func matchingNonceApplies() {
        let frame = RemotePrefixCacheContext(
            cacheScope: "frame-scope", cacheReceiptNonce: "n-1", repeatedPrefixTokens: 0)
        let resolved = frame.applying(
            sealed: SealedPrefixCacheMetadata(
                receiptNonce: "n-1", scope: "sealed-scope", repeatedPrefixTokens: 1024))
        #expect(resolved.scope == "sealed-scope")
        #expect(resolved.receiptNonce == "n-1")
        #expect(resolved.repeatedPrefixTokens == 1024)

        let withoutFrameScope = RemotePrefixCacheContext(cacheScope: nil, cacheReceiptNonce: "n-1")
            .applying(
                sealed: SealedPrefixCacheMetadata(
                    receiptNonce: "n-1", scope: "sealed-scope", repeatedPrefixTokens: nil))
        #expect(withoutFrameScope.cacheEnabled)
        #expect(withoutFrameScope.scope == "sealed-scope")
        #expect(withoutFrameScope.repeatedPrefixTokens == nil)
    }

    @Test("a copy with another nonce, or a frame with no nonce, leaves the frame's values")
    func otherNonceIgnored() {
        let copy = SealedPrefixCacheMetadata(
            receiptNonce: "caller-written", scope: "other-scope", repeatedPrefixTokens: 4096)
        let frame = RemotePrefixCacheContext(
            cacheScope: "frame-scope", cacheReceiptNonce: "n-1", repeatedPrefixTokens: 0)
        #expect(frame.applying(sealed: copy) == frame)

        let cold = RemotePrefixCacheContext(cacheScope: nil, cacheReceiptNonce: nil)
        let coldResolved = cold.applying(
            sealed: SealedPrefixCacheMetadata(
                receiptNonce: "n-1", scope: "sealed-scope", repeatedPrefixTokens: nil))
        #expect(coldResolved == cold)
        #expect(!coldResolved.cacheEnabled)

        #expect(frame.applying(sealed: nil) == frame)
    }
}
