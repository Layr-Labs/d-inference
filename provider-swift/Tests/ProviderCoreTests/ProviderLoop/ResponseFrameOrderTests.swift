import Foundation
import Testing

@testable import ProviderCore

#if DEBUG
/// The order of a served request's response frames, and the usage sealed
/// after them, as the coordinator receives them from `ProviderLoop.run()`.
@Suite("Response frame order", .serialized)
struct ResponseFrameOrderTests {
    @Test("a served request's chunks are numbered from 0 under one prefix of its own")
    func chunksAreNumberedInOrder() async throws {
        let fixture = try await ServeLoopFixture.make()
        let task = fixture.start()
        _ = try await fixture.awaitRegistration()

        var prefixes: [[UInt8]] = []
        for (index, requestId) in ["first", "second"].enumerated() {
            try await fixture.pushChatRequest(requestId: requestId)
            try await fixture.awaitSubmissions(index + 1)
            fixture.completeSubmission(index)
            let done = try await fixture.mock.waitForSnapshot(timeout: .seconds(10)) {
                $0.inferenceComplete.contains { $0.requestId == requestId }
            }
            let chunks = try #require(done).inferenceChunks.filter { $0.requestId == requestId }
            #expect(chunks.count >= 2)
            let numbered = try chunks.map { try responseFrameNumber(#require($0.encryptedData)) }
            #expect(Set(numbered.map(\.prefix)).count == 1)
            #expect(numbered.map(\.number) == Array(0..<UInt64(chunks.count)))
            prefixes.append(numbered[0].prefix)
        }
        #expect(prefixes[0] != prefixes[1])

        #expect(await fixture.stop(task))
    }

    @Test("inference_complete carries its usage sealed after the last chunk, beside the plaintext usage")
    func completeCarriesTheSealedUsage() async throws {
        let fixture = try await ServeLoopFixture.make()
        let task = fixture.start()
        _ = try await fixture.awaitRegistration()

        let consumer = NodeKeyPair.generate()
        try await fixture.pushChatRequest(requestId: "sealed-usage", consumer: consumer)
        try await fixture.awaitSubmissions(1)
        fixture.completeSubmission(0)
        let done = try await fixture.mock.waitForSnapshot(timeout: .seconds(10)) {
            $0.inferenceComplete.contains { $0.requestId == "sealed-usage" }
        }
        let snapshot = try #require(done)
        let complete = try #require(snapshot.inferenceComplete.first { $0.requestId == "sealed-usage" })
        let chunks = snapshot.inferenceChunks.filter { $0.requestId == "sealed-usage" }
        let first = try responseFrameNumber(#require(chunks.first?.encryptedData))

        let sealed = try #require(complete.encryptedUsage)
        let numbered = try responseFrameNumber(sealed)
        #expect(numbered.prefix == first.prefix)
        #expect(numbered.number == UInt64(chunks.count))
        let opened = try JSONDecoder().decode(SealedResponseUsage.self, from: consumer.decryptPayload(sealed))
        #expect(opened.frameCount == UInt64(chunks.count))
        #expect(opened.usage == complete.usage)
        #expect(complete.usage.promptTokens == 3)
        #expect(complete.usage.completionTokens == 1)

        #expect(await fixture.stop(task))
    }
}
#endif
