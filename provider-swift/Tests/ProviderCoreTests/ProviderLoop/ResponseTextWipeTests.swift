import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

#if DEBUG
/// The response text the inference handler gathers while it streams (for the
/// response hash, the billing floor and the reasoning count) is zeroed when the
/// request ends: a text that exists whole only in that gathered response is
/// gone from memory once the request has finished. The response here is
/// content; reasoning and tool calls go into the same `ResponseTextBuffer`s.
@Suite(.serialized) struct ResponseTextWipeTests {
    private final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks = 0
        private var completed = false
        func record(_ message: OutboundMessage) {
            lock.withLock {
                switch message {
                case .inferenceChunk: chunks += 1
                case .inferenceComplete: completed = true
                default: break
                }
            }
        }
        var chunkCount: Int { lock.withLock { chunks } }
        var isCompleted: Bool { lock.withLock { completed } }
    }

    @Test func gatheredResponseTextIsZeroedWhenTheRequestEnds() async throws {
        let scripted = try await ScriptedRequestLoop.make(providerName: "response-text")

        let request = try JSONSerialization.data(withJSONObject: [
            "model": "fixture-model", "messages": [["role": "user", "content": "fixture"]],
            "max_tokens": 4096, "stream": true, "reasoning_parser": "none",
        ])
        let sent = Sent()
        let continuation = try await scripted.start(request: request, requestId: "response-text-request",
                                                    send: SendHandle(sent.record))

        // The response repeats `text` in quarter pieces, one frame each, so
        // only the gathered response ever holds it whole.
        let text = UnheldText.random(count: 2048)
        let quarter = text.count / 4
        var frames = 0
        for _ in 0 ..< 32 {
            for part in 0 ..< 4 {
                let chunksBefore = sent.chunkCount
                continuation.yield(.delta(
                    text: text.piece(part * quarter ..< (part + 1) * quarter), tokens: [5], logprobs: nil))
                frames += 1
                let sentUntil = ContinuousClock.now + .seconds(5)
                while sent.chunkCount == chunksBefore, ContinuousClock.now < sentUntil {
                    try await Task.sleep(for: .milliseconds(1))
                }
            }
        }
        #expect(!ProcessMemoryScan.copies(of: text).isEmpty, "the scan finds the response while it is gathered")

        continuation.yield(.finished(reason: .length, usage: .init(promptTokens: 3, completionTokens: frames)))
        continuation.finish()
        let completedUntil = ContinuousClock.now + .seconds(10)
        while !sent.isCompleted, ContinuousClock.now < completedUntil {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(sent.isCompleted)

        // The request's task ends right after its terminal message; on a busy
        // runner give it up to 10 s before reading memory for the last time.
        let endedUntil = ContinuousClock.now + .seconds(10)
        while !ProcessMemoryScan.copies(of: text).isEmpty, ContinuousClock.now < endedUntil {
            try await Task.sleep(for: .milliseconds(500))
        }
        ProcessMemoryScan.expectNoCopies(of: text, after: "the request ended")
        await scripted.shutdown()
    }
}
#endif
