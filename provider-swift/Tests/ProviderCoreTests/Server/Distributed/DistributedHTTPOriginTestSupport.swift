import Foundation
import Hummingbird
import MLXLMCommon
import NIOCore
@testable import ProviderCore

final class HTTPOriginCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var instants: [String: ContinuousClock.Instant] = [:]
    private var origin: ContinuousClock.Instant?
    private var text = ""
    private var releases = 0
    func bodyEntered() {
        lock.withLock {
            origin = DistributedRequestOrigin.current
            instants["body"] = .now
        }
    }
    func mark(_ name: String) { lock.withLock { instants[name] = .now } }
    func instant(_ name: String) -> ContinuousClock.Instant? { lock.withLock { instants[name] } }
    var receivedAt: ContinuousClock.Instant? { lock.withLock { origin } }
    func append(_ value: String) { lock.withLock { text += value } }
    var output: String { lock.withLock { text } }
    func release() { lock.withLock { releases += 1 } }
    var releaseCount: Int { lock.withLock { releases } }
}

/// Consumption is delayed inside the actual Hummingbird collectBody path.
struct HTTPOriginBody: AsyncSequence, Sendable {
    typealias Element = ByteBuffer
    let json: String
    let delay: Duration
    let capture: HTTPOriginCapture
    struct AsyncIterator: AsyncIteratorProtocol {
        let body: HTTPOriginBody
        var delivered = false
        mutating func next() async throws -> ByteBuffer? {
            guard !delivered else { return nil }
            delivered = true
            body.capture.bodyEntered()
            try await Task.sleep(for: body.delay)
            body.capture.mark("bodyReady")
            return ByteBuffer(string: body.json)
        }
    }
    func makeAsyncIterator() -> AsyncIterator { .init(body: self) }
}

struct HTTPOriginWriter: ResponseBodyWriter {
    let capture: HTTPOriginCapture
    mutating func write(_ buffer: ByteBuffer) async throws {
        capture.append(String(buffer: buffer))
    }
    consuming func finish(_ trailingHeaders: HTTPFields?) async throws {}
}

struct HTTPOriginTokenizer: MLXLMCommon.Tokenizer {
    let capture: HTTPOriginCapture
    private let base = DistributedTestTokenizer()
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        base.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        base.decode(tokenIds: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
    var bosToken: String? { base.bosToken }
    var eosToken: String? { base.eosToken }
    var unknownToken: String? { base.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]],
                           tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        capture.mark("tokenize")
        Thread.sleep(forTimeInterval: 0.010)
        return [1, 2, 3]
    }
}

final class HTTPOriginOwner: DistributedDeadlineExecutionOwner, @unchecked Sendable {
    let base = DistributedTestOwner()
    private let lock = NSLock()
    private var captured: DistributedRequestDeadlineContext?
    var context: DistributedRequestDeadlineContext? { lock.withLock { captured } }
    func readiness() -> DistributedResidentReadiness? { base.readiness() }
    func setReadinessInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        base.setReadinessInvalidationHandler(handler)
    }
    func projectFirstToken(_ request: CBv2Request, admission: CBv2FirstTokenDeadlineAdmission) -> CBv2FirstTokenProjectedWork {
        base.projectFirstToken(request, admission: admission)
    }
    func reserve(_ request: CBv2Request, identity: DistributedResidentIdentity,
                 profileID: String, capacityLimit: Int) throws -> any DistributedResidentRequestLease {
        throw DistributedEngineError.invalidConfiguration("lost HTTP-origin context")
    }
    func reserve(_ request: CBv2Request, identity: DistributedResidentIdentity,
                 profileID: String, capacityLimit: Int,
                 deadlineContext: DistributedRequestDeadlineContext) throws -> any DistributedResidentRequestLease {
        lock.withLock { captured = deadlineContext }
        return try base.reserve(request, identity: identity, profileID: profileID, capacityLimit: capacityLimit)
    }
    func shutdown() async { await base.shutdown() }
}

final class HTTPOriginSoloEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var submissions = 0
    var submissionCount: Int { lock.withLock { submissions } }
    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        lock.withLock { submissions += 1 }
        return AsyncStream { $0.finish() }
    }
    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
              kvBytesCapacity: 0, activeTokens: 0)
    }
    func shutdown() async {}
}
