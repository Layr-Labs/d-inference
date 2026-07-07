// Copyright © 2026 Eigen Labs.
//
// Shared minimal CBv2 stubs for suites that need a ModelSlot but don't
// exercise generation (persistence, preload, idle-timeout, capacity guard
// tests). v0.7.5 slots REQUIRE a v2 bridge — these keep such suites
// weight-free.

import Foundation
import MLXLMCommon

@testable import ProviderCore

/// Inert engine: accepts nothing, reports a fixed KV capacity, tracks
/// `updateKVBytesCapacity` calls so re-slice tests can assert grant flow.
final class InertStubEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var _kvBytesCapacity: Int
    private var _capacityUpdates: [Int] = []
    private var _shutdownCalls = 0

    init(kvBytesCapacity: Int = 0) {
        self._kvBytesCapacity = kvBytesCapacity
    }

    var capacityUpdates: [Int] { lock.withLock { _capacityUpdates } }
    var shutdownCalls: Int { lock.withLock { _shutdownCalls } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        continuation.finish()
        return stream
    }
    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        lock.withLock {
            CBv2CapacitySnapshot(
                activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
                kvBytesCapacity: _kvBytesCapacity, activeTokens: 0)
        }
    }
    func updateKVBytesCapacity(_ bytes: Int) {
        lock.withLock {
            _kvBytesCapacity = max(0, bytes)
            _capacityUpdates.append(max(0, bytes))
        }
    }
    func shutdown() async {
        lock.withLock { _shutdownCalls += 1 }
    }
}

/// Minimal tokenizer for stub bridges (never drives generation).
struct StubBridgeTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] { [] }
}

/// A slot-shaped stub bridge over an inert engine — enough for install/
/// unload/persistence/capacity-guard suites.
func makeInertStubBridge(
    modelId: String, kvBytesCapacity: Int = 0
) -> (bridge: EngineV2Bridge, engine: InertStubEngine) {
    let engine = InertStubEngine(kvBytesCapacity: kvBytesCapacity)
    let bridge = EngineV2Bridge(
        engine: engine,
        modelId: modelId,
        tokenizer: TokenizerHandle(StubBridgeTokenizer()),
        eosTokenIds: []
    )
    return (bridge, engine)
}
