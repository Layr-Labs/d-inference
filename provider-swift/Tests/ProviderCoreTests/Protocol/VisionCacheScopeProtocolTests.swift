import Foundation
import Testing
@testable import ProviderCore

@Test func visionScopeIsOptionalOuterMetadataIndependentOfPrefixScope() throws {
    let old = try ProviderProtocolCodec.decodeCoordinatorMessage(from:
        Data(#"{"type":"inference_request","request_id":"old","cache_scope":"prefix"}"#.utf8))
    guard case .inferenceRequest(let legacy) = old else { Issue.record("wrong message"); return }
    #expect(legacy.visionCacheScope == nil)
    #expect(legacy.cacheScope == "prefix")
    let message = CoordinatorMessage.inferenceRequest(.init(requestId: "new",
        cacheReceiptNonce: "nonce", cacheScope: "prefix", visionCacheScope: "vision", prefixCacheProtocol: 2))
    let data = try JSONEncoder().encode(message)
    let wire = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(wire["vision_cache_scope"] as? String == "vision")
    #expect(wire["cache_scope"] as? String == "prefix")
    guard case .inferenceRequest(let decoded) = try ProviderProtocolCodec.decodeCoordinatorMessage(from: data)
    else { Issue.record("wrong message"); return }
    #expect(decoded.visionCacheScope == "vision")
    #expect(decoded.cacheReceiptNonce == "nonce")
    #expect(decoded.prefixCacheProtocol == 2)
    let omitted = try JSONEncoder().encode(CoordinatorMessage.inferenceRequest(.init(requestId: "absent")))
    let absent = try #require(JSONSerialization.jsonObject(with: omitted) as? [String: Any])
    #expect(absent["vision_cache_scope"] == nil)
}
