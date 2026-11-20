import CryptoKit
import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// Plaintext that `NodeKeyPair` opens or seals is zeroed when its buffer is
/// released, so a finished request leaves no copy of it in freed memory. The
/// test reads its own process memory after each step.
@Suite(.serialized) struct RequestBufferWipeTests {
    /// Large enough that the allocator does not clear the block itself on free.
    static let bodySize = 256 * 1024

    @Test func openedAndSealedPlaintextIsZeroedWhenReleased() throws {
        let prompt = UnheldText.random(count: 32)
        let completion = UnheldText.random(count: 32)
        let provider = NodeKeyPair.generate()
        let coordinator = NodeKeyPair.generate()

        var bodyDigest: SHA256Digest?
        let sealed = try prompt.withRepeated(
            prefix: #"{"model":"m","messages":[{"role":"user","content":""#, suffix: #""}]}"#,
            size: Self.bodySize
        ) { body in
            bodyDigest = SHA256.hash(data: UnsafeRawBufferPointer(body))
            return try coordinator.encrypt(
                recipientPublicKey: provider.publicKeyBytes,
                plaintext: Data(bytesNoCopy: body.baseAddress!, count: body.count, deallocator: .none))
        }
        ProcessMemoryScan.expectNoCopies(of: prompt, after: "sealing the request")

        do { // `body` is released before the scan.
            let body = try provider.decrypt(senderPublicKey: coordinator.publicKeyBytes, ciphertext: sealed)
            #expect(SHA256.hash(data: body) == bodyDigest)
        }
        ReleasedBufferWipe.waitForPendingForTesting()
        ProcessMemoryScan.expectNoCopies(of: prompt, after: "opening the request")

        let sharedKey = try provider.precomputeSharedKey(recipientPublicKey: coordinator.publicKeyBytes)
        let payload = try completion.withRepeated(
            prefix: #"data: {"choices":[{"delta":{"content":""#, suffix: "\"}}]}\n\n",
            size: Self.bodySize
        ) { chunk in
            try provider.encryptPayloadFast(
                sharedKey: sharedKey,
                plaintext: Data(bytesNoCopy: chunk.baseAddress!, count: chunk.count, deallocator: .none))
        }
        ProcessMemoryScan.expectNoCopies(of: completion, after: "sealing the response")

        // The scan finds each text while a buffer still holds it.
        let reopened = try provider.decrypt(senderPublicKey: coordinator.publicKeyBytes, ciphertext: sealed)
        withExtendedLifetime(reopened) { #expect(ProcessMemoryScan.containsCopy(of: prompt)) }
        let chunk = try coordinator.decrypt(
            senderPublicKey: provider.publicKeyBytes, ciphertext: try #require(Data(base64Encoded: payload.ciphertext)))
        withExtendedLifetime(chunk) { #expect(ProcessMemoryScan.containsCopy(of: completion)) }
    }

    /// Opening a request zeroes nothing, and releasing the body only queues
    /// its zeroing: the opened text stays until the wipe queue runs.
    @Test func releasedBodyIsZeroedOnTheWipeQueue() throws {
        let prompt = UnheldText.random(count: 32)
        let provider = NodeKeyPair.generate()
        let coordinator = NodeKeyPair.generate()
        let sealed = try prompt.withRepeated(
            prefix: #"{"model":"m","messages":[{"role":"user","content":""#, suffix: #""}]}"#,
            size: Self.bodySize
        ) { body in
            try coordinator.encrypt(
                recipientPublicKey: provider.publicKeyBytes,
                plaintext: Data(bytesNoCopy: body.baseAddress!, count: body.count, deallocator: .none))
        }

        ReleasedBufferWipe.suspendForTesting()
        var suspended = true
        defer { if suspended { ReleasedBufferWipe.resumeForTesting() } }
        do { // `body` is released before the scan.
            let body = try provider.decrypt(senderPublicKey: coordinator.publicKeyBytes, ciphertext: sealed)
            #expect(body.count > Self.bodySize / 2)
        }
        #expect(ProcessMemoryScan.containsCopy(of: prompt), "released, and not zeroed before the queue runs")

        ReleasedBufferWipe.resumeForTesting()
        suspended = false
        ReleasedBufferWipe.waitForPendingForTesting()
        ProcessMemoryScan.expectNoCopies(of: prompt, after: "the wipe queue ran")
    }
}

#if DEBUG
extension RequestBufferWipeTests {
    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []
        func append(_ event: String) { lock.withLock { events.append(event) } }
        var snapshot: [String] { lock.withLock { events } }
    }

    /// The handler keeps a request's decrypted body until the request's last
    /// message has been sent; only then is it released and its zeroing queued.
    @Test func requestBodyIsZeroedAfterTheRequestsLastMessage() async throws {
        let scripted = try await ScriptedRequestLoop.make(providerName: "buffer-wipe")

        // A body length that no other buffer in the test process is likely to share.
        let request = try JSONSerialization.data(withJSONObject: [
            "model": "fixture-model",
            "messages": [["role": "user", "content": String(repeating: "x", count: .random(in: 1_500 ..< 3_500))]],
            "max_tokens": 1, "stream": true, "reasoning_parser": "none",
        ])
        let events = EventLog()
        let bodyCount = request.count
        ReleasedBufferWipe.observeForTesting { count in
            if count == bodyCount { events.append("zeroed") }
        }
        defer { ReleasedBufferWipe.observeForTesting(nil) }

        let continuation = try await scripted.start(request: request, requestId: "wipe-request-id",
            send: SendHandle { message in
                switch message {
                case .inferenceChunk: events.append("chunk")
                case .inferenceComplete: events.append("complete")
                case .inferenceError: events.append("error")
                default: break
                }
            })
        #expect(!events.snapshot.contains("zeroed"), "zeroed before the first token")
        continuation.yield(.delta(text: "a", tokens: [5], logprobs: nil))
        continuation.yield(.finished(reason: .length, usage: .init(promptTokens: 3, completionTokens: 1)))
        continuation.finish()

        let zeroedUntil = ContinuousClock.now + .seconds(30)
        while !events.snapshot.contains("zeroed"), ContinuousClock.now < zeroedUntil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let order = events.snapshot
        #expect(order.contains("chunk"), "\(order)")
        #expect(order.contains("complete"), "\(order)")
        #expect(order.filter { $0 == "zeroed" }.count == 1, "\(order)")
        #expect(order.last == "zeroed", "zeroed before the request's last message: \(order)")
        await scripted.shutdown()
    }
}
#endif
