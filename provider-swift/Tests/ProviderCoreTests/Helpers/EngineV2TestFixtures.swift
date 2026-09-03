// Copyright © 2026 Eigen Labs.
//
// Common deterministic fixtures for EngineV2 bridge and production-wiring tests.

import Foundation
import MLXLMCommon

@testable import ProviderCore

/// In-process scripted CBv2 engine shared by bridge and production-wiring tests.
/// Thread-safe because engine actors and tests inspect it concurrently.
final class ScriptedCBv2Engine: CBv2Engine, @unchecked Sendable {
    enum Script {
        case throwOnSubmit(any Error)
        case stream([CBv2Event])
        case manual
    }

    private let lock = NSLock()
    private let script: Script
    private var _submitted: [CBv2Request] = []
    private var _cancelled: [CBv2RequestID] = []
    private var _shutdownCalls = 0
    private var _manualContinuations: [AsyncStream<CBv2Event>.Continuation] = []
    private var _capacitySnapshot: CBv2CapacitySnapshot
    private let tracksSubmittedRequests: Bool
    private let kvBytesBackendCapacity: Int
    private var _capacityUpdates: [Int] = []

    /// Fixed-snapshot mode used by bridge tests. The snapshot remains directly
    /// mutable so liveness tests can advance its scripted step counter.
    init(
        script: Script,
        capacity: CBv2CapacitySnapshot = CBv2CapacitySnapshot(
            activeRequests: 0,
            waitingRequests: 0,
            kvBytesInUse: 0,
            kvBytesCapacity: 0,
            activeTokens: 0
        )
    ) {
        self.script = script
        self._capacitySnapshot = capacity
        self.tracksSubmittedRequests = false
        self.kvBytesBackendCapacity = capacity.kvBytesBackendCapacity
    }

    /// Submission-tracked mode used by production-wiring tests. Its logical KV
    /// capacity is resizable while the physical paged capacity remains fixed.
    init(script: Script, kvBytesCapacity: Int, kvBytesBackendCapacity: Int = 0) {
        self.script = script
        self._capacitySnapshot = CBv2CapacitySnapshot(
            activeRequests: 0,
            waitingRequests: 0,
            kvBytesInUse: 0,
            kvBytesCapacity: max(0, kvBytesCapacity),
            kvBytesBackendCapacity: max(0, kvBytesBackendCapacity),
            activeTokens: 0
        )
        self.tracksSubmittedRequests = true
        self.kvBytesBackendCapacity = max(0, kvBytesBackendCapacity)
    }

    var submitted: [CBv2Request] { lock.withLock { _submitted } }
    var cancelled: [CBv2RequestID] { lock.withLock { _cancelled } }
    var shutdownCalls: Int { lock.withLock { _shutdownCalls } }
    var manualContinuation: AsyncStream<CBv2Event>.Continuation? {
        lock.withLock { _manualContinuations.last }
    }
    var capacityUpdates: [Int] { lock.withLock { _capacityUpdates } }
    var capacitySnapshot: CBv2CapacitySnapshot {
        get { lock.withLock { _capacitySnapshot } }
        set { lock.withLock { _capacitySnapshot = newValue } }
    }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let script = lock.withLock { () -> Script in
            _submitted.append(request)
            return self.script
        }
        switch script {
        case .throwOnSubmit(let error):
            throw error
        case .stream(let events):
            let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
            return stream
        case .manual:
            let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
            lock.withLock { _manualContinuations.append(continuation) }
            return stream
        }
    }

    func cancel(_ id: CBv2RequestID) {
        lock.withLock { _cancelled.append(id) }
    }

    func capacity() -> CBv2CapacitySnapshot {
        lock.withLock {
            var snapshot = _capacitySnapshot
            if tracksSubmittedRequests {
                snapshot.activeRequests = max(0, _submitted.count - _cancelled.count)
                snapshot.kvBytesBackendCapacity = kvBytesBackendCapacity
            }
            return snapshot
        }
    }

    func updateKVBytesCapacity(_ bytes: Int) {
        lock.withLock {
            let capacity = max(0, bytes)
            _capacitySnapshot.kvBytesCapacity = capacity
            _capacityUpdates.append(capacity)
        }
    }

    func shutdown() async {
        lock.withLock { _shutdownCalls += 1 }
    }
}

/// Fixed-output tokenizer with configurable template and ID-token behavior.
/// Bridge fixtures leave ID conversion unavailable; production fixtures enable
/// scalar conversion to model the server tokenizer contract.
struct StubTokenizer: MLXLMCommon.Tokenizer {
    enum IDTokenConversion: Sendable {
        case unavailable
        case unicodeScalar
    }

    var templateTokens: [Int] = [1, 2, 3, 4, 5]
    var tokenTable: [String: Int] = ["</s>": 2, "<|eot|>": 7]
    var eosTokenString: String? = "</s>"
    var failTemplate = false
    var decodeOverride: String?
    var idTokenConversion: IDTokenConversion = .unavailable

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        Array(repeating: 0, count: text.count)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        if let decodeOverride { return decodeOverride }
        return tokenIds.map { "t\($0)" }.joined()
    }

    func convertTokenToId(_ token: String) -> Int? { tokenTable[token] }

    func convertIdToToken(_ id: Int) -> String? {
        guard idTokenConversion == .unicodeScalar else { return nil }
        if let token = tokenTable.first(where: { $0.value == id })?.key { return token }
        guard id >= 0, id < 128, let scalar = UnicodeScalar(id) else { return nil }
        return String(Character(scalar))
    }

    var bosToken: String? { nil }
    var eosToken: String? { eosTokenString }
    var unknownToken: String? { nil }

    struct TemplateError: Error {}

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        if failTemplate { throw TemplateError() }
        return templateTokens
    }
}

/// Thread-safe telemetry recorder shared by EngineV2 tests.
final class TelemetrySink: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [TelemetryEvent] = []

    var events: [TelemetryEvent] { lock.withLock { _events } }

    func callback() -> @Sendable (TelemetryEvent) -> Void {
        { [weak self] event in
            guard let self else { return }
            self.lock.withLock { self._events.append(event) }
        }
    }
}
