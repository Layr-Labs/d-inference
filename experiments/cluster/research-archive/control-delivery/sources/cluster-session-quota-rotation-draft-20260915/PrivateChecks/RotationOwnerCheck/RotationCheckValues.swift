import Foundation
import Darwin
import MLXLMCommon
@testable import ProviderCore

struct RotationCheckError: Error { let message: String }

func rotationRequire(_ value: Bool, _ message: String) throws {
    if !value { throw RotationCheckError(message: message) }
}

func rotationDeadline(_ seconds: UInt64 = 5) -> UInt64 {
    DispatchTime.now().uptimeNanoseconds + seconds * 1_000_000_000
}

func rotationEventually(seconds: Int = 5, _ predicate: () async -> Bool) async throws {
    let end = ContinuousClock.now.advanced(by: .seconds(seconds))
    while ContinuousClock.now < end {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw RotationCheckError(message: "Bounded condition did not become true")
}

/// Only tokenization is fabricated. The real HTTP/bridge/engine, installed
/// session, owner service, process transport and native-protocol child execute.
struct RotationTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1, 2, 3] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { tokenIds.map { "t\($0)" }.joined() }
    func convertTokenToId(_ token: String) -> Int? { token == "</s>" ? 99 : nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { "</s>" }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] { [1, 2, 3] }
}

final class RotationDiscovery: @unchecked Sendable {
    private let lock = NSLock()
    private var record: LocalEndpoint.Info?
    private var writes = 0
    var value: LocalEndpoint.Info? { lock.withLock { record } }
    var writeCount: Int { lock.withLock { writes } }
    var client: DistributedLocalDiscovery {
        .init(publish: { value in self.lock.withLock { self.record = value; self.writes += 1 } },
              removeIfOwned: { own in self.lock.withLock {
                  DistributedLocalDiscovery.remove(own, read: { self.record }, remove: { self.record = nil })
              } })
    }
}

/// The gate blocks only the second generation's second endpoint factory. It
/// always ends within two seconds and then throws; it cannot launch a late
/// child after explicit stop. Rank zero has already been owned at that point.
final class RotationStartupGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var entered = false
    var isEntered: Bool { lock.withLock { entered } }
    func waitThenRefuse() throws {
        lock.withLock { entered = true }
        _ = release.wait(timeout: .now() + 2)
        throw RotationCheckError(message: "Deliberate second-rank startup refusal")
    }
    func open() { release.signal() }
}
