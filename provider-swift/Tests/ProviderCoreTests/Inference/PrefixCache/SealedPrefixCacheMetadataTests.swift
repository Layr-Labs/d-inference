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

    /// Today's coordinators send no copy: the request decodes and resolves its cache identity exactly as on a
    /// build without the copy, and a member a caller wrote (without the attempt's receipt nonce) changes nothing.
    @Test("without the attempt's copy the request and its cache identity are exactly as before")
    func withoutTheCopyNothingChanges() throws {
        let plain = #"""
            {"model":"m","messages":[{"role":"user","content":"hi"}],"seed":7,"temperature":0.5,
             "logprobs":true,"top_logprobs":2}
            """#
        let inbound = try ProviderLoop.decodeInboundChatRequest(Data(plain.utf8))
        #expect(inbound.extensions.sealedPrefixCache == nil)
        let frames = [
            RemotePrefixCacheContext(cacheScope: "frame-scope", cacheReceiptNonce: "n-1", repeatedPrefixTokens: 4096),
            RemotePrefixCacheContext(cacheScope: nil, cacheReceiptNonce: "n-2"),
            RemotePrefixCacheContext(cacheScope: nil, cacheReceiptNonce: nil),
        ]
        for frame in frames {
            #expect(frame.applying(sealed: inbound.extensions.sealedPrefixCache) == frame)
        }
        var object = try #require(JSONSerialization.jsonObject(with: Data(plain.utf8)) as? [String: Any])
        object["_darkbloom_cache"] = ["nonce": "guessed", "scope": "other-scope", "repeated_prefix_tokens": 9]
        let written = try ProviderLoop.decodeInboundChatRequest(try JSONSerialization.data(withJSONObject: object))
        #expect(String(reflecting: written.request) == String(reflecting: inbound.request))
        #expect(written.extensions.templateControls == inbound.extensions.templateControls)
        #expect(written.extensions.samplingOverrides == inbound.extensions.samplingOverrides)
        #expect(written.extensions.logprobsSpec?.topLogprobs == inbound.extensions.logprobsSpec?.topLogprobs)
        #expect(written.extensions.logprobsSpec?.requested == inbound.extensions.logprobsSpec?.requested)
        for frame in frames {
            #expect(frame.applying(sealed: written.extensions.sealedPrefixCache) == frame)
        }
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

        let keepsFrameDemand = RemotePrefixCacheContext(
            cacheScope: "frame-scope", cacheReceiptNonce: "n-1", repeatedPrefixTokens: 2048)
            .applying(
                sealed: SealedPrefixCacheMetadata(
                    receiptNonce: "n-1", scope: "sealed-scope", repeatedPrefixTokens: nil))
        #expect(keepsFrameDemand.scope == "sealed-scope")
        #expect(keepsFrameDemand.repeatedPrefixTokens == 2048)

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
