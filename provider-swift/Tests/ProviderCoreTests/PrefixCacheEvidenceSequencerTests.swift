import Foundation
import Testing

@testable import ProviderCore

@Suite("Prefix cache terminal delivery during shutdown")
struct PrefixCacheEvidenceSequencerTests {
    private final class Messages: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [OutboundMessage] = []

        func append(_ value: OutboundMessage) { lock.withLock { values.append(value) } }
        var snapshot: [OutboundMessage] { lock.withLock { values } }
    }

    private final class Pause: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = false
        private var entered = false
        let resume = DispatchSemaphore(value: 0)

        func arm() { lock.withLock { armed = true } }

        func pauseOnce() {
            let shouldPause = lock.withLock {
                guard armed else { return false }
                armed = false
                return true
            }
            if shouldPause {
                lock.withLock { entered = true }
                _ = resume.wait(timeout: .now() + 5)
            }
        }

        func waitUntilEntered() async -> Bool {
            for _ in 0 ..< 1000 {
                if lock.withLock({ entered }) { return true }
                try? await Task.sleep(for: .milliseconds(2))
            }
            return false
        }
    }

    private final class WeakSequencer {
        weak var value: PrefixCacheEvidenceSequencer?

        init(_ value: PrefixCacheEvidenceSequencer?) { self.value = value }
    }

    @Test("closed cache still forwards completion and error exactly once", arguments: [false, true])
    func terminalAfterShutdown(completed: Bool) async throws {
        let sequencer = makeSequencer()
        let messages = Messages()
        let send = SendHandle(messages.append)
        let callbacks = try #require(sequencer.callbacks(requestID: "r", nonce: "n", send: send))
        sequencer.shutdown()

        callbacks.lookup(lookup())
        callbacks.ready(ready())
        callbacks.terminal(terminal(completed: completed))
        callbacks.terminal(terminal(completed: completed))

        await waitForMessages(messages, count: 1)
        #expect(messageKinds(messages.snapshot) == [completed ? "complete:r" : "error:r"])
        #expect(sequencer.callbacks(requestID: "new", nonce: "new", send: send) == nil)
    }

    @Test("deallocated cache falls back without retaining the loaded model", arguments: [false, true])
    func terminalAfterDeallocation(completed: Bool) throws {
        var sequencer: PrefixCacheEvidenceSequencer? = makeSequencer()
        let released = WeakSequencer(sequencer)
        let messages = Messages()
        let callbacks = try #require(sequencer?.callbacks(
            requestID: "r", nonce: "n", send: SendHandle(messages.append)))
        sequencer = nil
        #expect(released.value == nil)

        callbacks.lookup(lookup())
        callbacks.ready(ready())
        callbacks.terminal(terminal(completed: completed))
        callbacks.terminal(terminal(completed: completed))

        #expect(messageKinds(messages.snapshot) == [completed ? "complete:r" : "error:r"])
    }

    @Test("accepted lookup survives teardown and precedes a post-shutdown terminal")
    func acceptedCommandsRetainUntilDrained() async throws {
        let capability = capability()
        let pause = Pause()
        var sequencer: PrefixCacheEvidenceSequencer? = PrefixCacheEvidenceSequencer {
            pause.pauseOnce()
            return capability
        }
        let released = WeakSequencer(sequencer)
        let messages = Messages()
        let callbacks = try #require(sequencer?.callbacks(
            requestID: "r", nonce: "n", send: SendHandle(messages.append)))
        pause.arm()
        callbacks.lookup(lookup())
        defer { pause.resume.signal() }
        #expect(await pause.waitUntilEntered())
        sequencer?.shutdown()
        sequencer = nil
        #expect(released.value != nil)

        callbacks.terminal(terminal())
        #expect(messages.snapshot.isEmpty)
        pause.resume.signal()
        await waitForMessages(messages, count: 2)
        #expect(messageKinds(messages.snapshot) == ["lookup:r", "error:r"])

        for _ in 0 ..< 1000 where released.value != nil {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(released.value == nil)
    }

    @Test("outer finalizer preserves lookup-before-terminal when recovery closes the cache")
    func finalizerDuringRecovery() async throws {
        let sequencer = makeSequencer()
        let messages = Messages()
        let send = SendHandle(messages.append)
        let callbacks = try #require(sequencer.callbacks(requestID: "r", nonce: "n", send: send))
        let finalizer = PrefixCacheLookupReceiptFinalizer(callback: nil)
        finalizer.configureV2(lookup: callbacks.lookup, terminal: callbacks.terminal)
        finalizer.resolve(lookup())
        sequencer.shutdown()
        finalizer.sendTerminal(terminal(), fallbackFailure: .policy, send: send)

        await waitForMessages(messages, count: 2)
        #expect(messageKinds(messages.snapshot) == ["lookup:r", "error:r"])
    }

    @Test("secondary tier never duplicates the primary terminal after shutdown or deallocation")
    func secondaryTierDoesNotForward() async throws {
        var sequencer: PrefixCacheEvidenceSequencer? = makeSequencer()
        let messages = Messages()
        let callbacks = try #require(sequencer?.callbacks(
            requestID: "r", nonce: "n", send: SendHandle(messages.append), forwardTerminal: false))
        let afterRelease = try #require(sequencer?.callbacks(
            requestID: "released", nonce: "released", send: SendHandle(messages.append),
            forwardTerminal: false))
        sequencer?.shutdown()
        callbacks.terminal(terminal())
        for _ in 0 ..< 1000 {
            if await sequencer?.requestStateSnapshotForTesting(nonce: "n")?.terminalSeen == true { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(await sequencer?.requestStateSnapshotForTesting(nonce: "n")?.terminalSeen == true)
        let released = WeakSequencer(sequencer)
        sequencer = nil
        for _ in 0 ..< 1000 where released.value != nil {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(released.value == nil)
        afterRelease.terminal(terminal(requestID: "released"))
        #expect(messages.snapshot.isEmpty)
    }

    @Test("racing shutdown and finalizers neither lose terminals nor reorder accepted lookups")
    func concurrentShutdown() async throws {
        let sequencer = makeSequencer()
        let messages = Messages()
        let send = SendHandle(messages.append)
        let callbacks = try (0 ..< 64).map { index in
            try #require(sequencer.callbacks(requestID: "r\(index)", nonce: "n\(index)", send: send))
        }
        let result = lookup()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { sequencer.shutdown() }
            for (index, callback) in callbacks.enumerated() {
                group.addTask {
                    callback.lookup(result)
                    await Task.yield()
                    callback.terminal(terminal(requestID: "r\(index)"))
                }
            }
        }
        for _ in 0 ..< 1000 {
            if messageKinds(messages.snapshot).filter({ $0.hasPrefix("error:") }).count == 64 { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        let kinds = messageKinds(messages.snapshot)
        for index in 0 ..< 64 {
            let terminals = kinds.indices.filter { kinds[$0] == "error:r\(index)" }
            #expect(terminals.count == 1)
            if let lookupIndex = kinds.firstIndex(of: "lookup:r\(index)"), let terminalIndex = terminals.first {
                #expect(lookupIndex < terminalIndex)
            }
        }
    }

    @Test("concurrent duplicate terminals forward once even with no cache owner", arguments: [false, true])
    func concurrentDuplicates(releaseOwner: Bool) async throws {
        var sequencer: PrefixCacheEvidenceSequencer? = makeSequencer()
        let messages = Messages()
        let callbacks = try #require(sequencer?.callbacks(
            requestID: "r", nonce: "n", send: SendHandle(messages.append)))
        sequencer?.shutdown()
        if releaseOwner { sequencer = nil }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 64 {
                group.addTask { callbacks.terminal(terminal()) }
            }
        }
        await waitForMessages(messages, count: 1)
        #expect(messageKinds(messages.snapshot) == ["error:r"])
        withExtendedLifetime(sequencer) {}
    }

    private func makeSequencer() -> PrefixCacheEvidenceSequencer {
        let value = capability()
        return PrefixCacheEvidenceSequencer { value }
    }

    private func capability() -> PrefixCacheV2Capability {
        PrefixCacheV2Capability(
            modelId: "model", modelAggregateHash: String(repeating: "a", count: 64),
            promptContractId: String(repeating: "b", count: 64), blockHashVersion: "dbk3",
            blockSize: 256, cacheEpoch: "11111111-1111-1111-1111-111111111111", enabled: true, ready: true)
    }

    private func lookup() -> PrefixCacheLookupResult {
        PrefixCacheLookupResult(outcome: .missAbsent, tier: .ssd,
            promptAnchor: PrefixCacheAnchor(chainHash: String(repeating: "c", count: 64), tokenCount: 256))
    }

    private func ready() -> PrefixCacheReadyResult {
        PrefixCacheReadyResult(readyTokens: 256, requiredRecomputeTokens: 0, expectedPrefillTokensSaved: 256,
            stageMs: 1, finalAnchor: PrefixCacheAnchor(chainHash: String(repeating: "c", count: 64), tokenCount: 256))
    }

    private func terminal(requestID: String = "r", completed: Bool = false) -> OutboundMessage {
        if completed {
            return .inferenceComplete(requestId: requestID, usage: UsageInfo(promptTokens: 1, completionTokens: 1),
                stopSequence: nil, seSignature: nil, responseHash: nil)
        }
        return .inferenceError(requestId: requestID, failure: InferenceFailure(code: .internalFailure, statusCode: 500))
    }

    private func messageKinds(_ messages: [OutboundMessage]) -> [String] {
        messages.map {
            switch $0 {
            case .prefixCacheLookupV2(let lookup): "lookup:\(lookup.requestId)"
            case .prefixCacheReadyV2(let ready): "ready:\(ready.requestId)"
            case .inferenceError(let requestID, _, _): "error:\(requestID)"
            case .inferenceComplete(let requestID, _, _, _, _, _): "complete:\(requestID)"
            default: "unexpected"
            }
        }
    }

    private func waitForMessages(_ messages: Messages, count: Int) async {
        for _ in 0 ..< 1000 where messages.snapshot.count < count {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}
