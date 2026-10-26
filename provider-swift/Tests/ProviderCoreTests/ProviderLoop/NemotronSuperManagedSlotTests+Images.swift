// Copyright © 2026 Eigen Labs.

import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import MLXLMCommon
import NIOCore
import Testing
@testable import ProviderCore

/// Images on the managed slot's default owner, which speculates for text:
/// coordinator and local-endpoint image requests run target-only beside
/// speculating text, and a media reservation that does not fit is refused
/// before anything is allocated.
extension NemotronSuperManagedSlotTests {
    /// 16x16 RGB PNG; decodes to one image tile.
    static let tinyPNG = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAF0lEQVR4nGP4z8BAEiJN9aiGUQ1DSgMAkPn/Afnh+ngAAAAASUVORK5CYII="

    /// One image and a question. `pieces` (nil: keep the script) scripts the output.
    static func imageBody(_ pieces: [String]?, script: SuperOutputScript, maxTokens: Int,
                          image: String = tinyPNG, question: String = "Describe.") throws -> Data {
        if let pieces { script.set(pieces) }
        return try JSONSerialization.data(withJSONObject: ["model": modelID, "stream": true,
            "temperature": 0, "max_tokens": maxTokens, "chat_template_kwargs": ["enable_thinking": false],
            "messages": [["role": "user", "content": [["type": "image_url", "image_url": ["url": image]],
                                                      ["type": "text", "text": question]]]]])
    }

    final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value?
        func set(_ value: Value) { lock.withLock { stored = value } }
        var value: Value? { lock.withLock { stored } }
    }

    @Test(.timeLimit(.minutes(3)))
    func imagesRunTargetOnlyBesideSpeculatingText() async throws {
        let fixture = try await Self.fixture(mode: .auto)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let loop = fixture.loop, script = fixture.script
        try await loop.ensureModelLoaded(modelId: Self.modelID, allowEviction: false,
                                         revisionDirectory: fixture.directory)
        let owner = try #require(await loop.nemotronSuperOwnerForTesting(modelId: Self.modelID))
        #expect(owner.speculates && owner.modelID == Self.modelID)
        let held = await fixture.budget.reservationBytesSnapshot()
        let recorder = Recorder(), consumer = NodeKeyPair.generate()

        // A coordinator image request alone: no round, draft or charge survives it.
        let before = await owner.bridge.mtpStatusSnapshot()
        let image = try await Self.send(Self.imageBody(["A", " cat", "."], script: script, maxTokens: 3),
                                        to: loop, recorder: recorder, consumer: consumer)
        #expect(SuperSSE(image.sse).content == "A cat.", "\(image.terminal)")
        let usage = try #require(Self.usage(image.terminal), "\(image.terminal)")
        #expect(usage.completionTokens == 3 && usage.promptTokens > 3)
        #expect(script.prompt.contains("<image>"))
        let afterImage = await owner.bridge.mtpStatusSnapshot()
        #expect(afterImage.rounds == before.rounds && afterImage.proposedTokens == before.proposedTokens)
        #expect(await fixture.budget.reservationBytesSnapshot() == held)

        // The unified local endpoint serves the same image on the same owner.
        let app = makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: "super-managed"), defaultMaxTokens: 16,
            acquire: { id in try await loop.acquireModelForLocal(id) },
            tokenizerProvider: { _ in throw MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization },
            availableModels: { [Self.modelID] }, mtpSlots: { [] },
            managedSuperEngine: { body, request, _ in
                guard request.model == Self.modelID else { return nil }
                return NemotronSuperLocalEndpointEngine(body: body, hasMedia: MediaIngest.hasMedia(request),
                    cacheScope: "local", acquire: { try await loop.acquireNemotronSuperForLocal(Self.modelID) })
            })
        try await app.test(.live) { client in
            let headers: HTTPFields = [.contentType: "application/json", .authorization: "Bearer super-managed"]
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: headers,
                body: ByteBuffer(bytes: try Self.imageBody(["A", " cat", "."], script: script,
                                                           maxTokens: 3))) { response in
                #expect(response.status == .ok)
                #expect(SuperSSE(String(buffer: response.body)).content == "A cat.")
            }
        }

        // A long speculating text request with an image arriving mid-stream:
        // both complete, the text keeps speculating, and every charge returns.
        let long = Array(repeating: "a", count: 400)
        let textBody = try Self.body(long, script: script)
        let concurrent = Box<(sse: String, terminal: OutboundMessage)>()
        let text = try await Self.send(textBody, to: loop, recorder: recorder, consumer: consumer) { id in
            let deadline = ContinuousClock.now + .seconds(30)
            while recorder.chunks(id).count < 3, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(1))
            }
            if let body = try? Self.imageBody(nil, script: script, maxTokens: 4),
               let result = try? await Self.send(body, to: loop, recorder: recorder, consumer: consumer) {
                concurrent.set(result)
            }
        }
        let textUsage = try #require(Self.usage(text.terminal), "\(text.terminal)")
        #expect(textUsage.completionTokens == 400 && SuperSSE(text.sse).content == long.joined())
        let mixedImage = try #require(concurrent.value)
        #expect(SuperSSE(mixedImage.sse).content == "aaaa", "\(mixedImage.terminal)")
        #expect(Self.usage(mixedImage.terminal)?.completionTokens == 4)
        let afterMixed = await owner.bridge.mtpStatusSnapshot()
        #expect(afterMixed.rounds > afterImage.rounds, "the text request kept speculating")
        #expect(await fixture.budget.reservationBytesSnapshot() == held)

        #expect(await loop.unloadModel(Self.modelID))
        #expect(await fixture.budget.reservationBytesSnapshot().isEmpty)
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
    }

    /// Room for the request's ingress but not its image: 503 before decoding,
    /// with every reservation returned; the same request then succeeds.
    @Test(.timeLimit(.minutes(3)))
    func imageThatDoesNotFitIsRefusedBeforeAllocation() async throws {
        let fixture = try await Self.fixture(mode: .auto)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let loop = fixture.loop, script = fixture.script, budget = fixture.budget
        try await loop.ensureModelLoaded(modelId: Self.modelID, allowEviction: false,
                                         revisionDirectory: fixture.directory)
        let body = try Self.imageBody(["x"], script: script, maxTokens: 1)
        let template = try #require(Data(base64Encoded: superImagePinnedTemplateBase64,
                                        options: .ignoreUnknownCharacters))
        let ingress = try NemotronSuperLocalImageBinding.encodedHeaderQuote(
            bodyBytes: body.count, templateBytes: template.count)
        let media = try NemotronSuperLocalImageBinding.encodedPlan(
            [try MediaIngest.dataFromDataURI(Self.tinyPNG)], contextLength: 1024).totalBytes
        // The largest reservation the budget still admits, to 1 MiB.
        var low: UInt64 = 0, high: UInt64 = 64 << 30
        while high - low > 1 << 20 {
            let mid = (low + high) / 2
            if await budget.reserveBytes(requestID: "super-probe", bytes: mid) {
                await budget.release(requestID: "super-probe"); low = mid
            } else { high = mid }
        }
        let filler = low - (ingress + media / 2)
        #expect(media / 2 > 1 << 20)
        #expect(await budget.reserveBytes(requestID: "super-filler", bytes: filler))
        let held = await budget.reservationBytesSnapshot()
        let recorder = Recorder(), consumer = NodeKeyPair.generate()
        let refused = try await Self.send(body, to: loop, recorder: recorder, consumer: consumer)
        let failure = try #require(Self.failure(refused.terminal), "\(refused.terminal)")
        #expect(failure.statusCode == 503 && failure.errorReason == .mediaMemoryUnavailable)
        #expect(refused.sse.isEmpty)
        #expect(await budget.reservationBytesSnapshot() == held)
        await budget.release(requestID: "super-filler")
        let served = try await Self.send(body, to: loop, recorder: recorder, consumer: consumer)
        #expect(SuperSSE(served.sse).content == "x", "\(served.terminal)")
        #expect(await loop.unloadModel(Self.modelID))
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    /// One image request runs at a time per owner: a second concurrent image
    /// gets 429 before any response and holds nothing; a video that is not a
    /// movie gets 400 from the shared inline ingest.
    @Test(.timeLimit(.minutes(3)))
    func concurrentImageIsRefusedWith429AndInvalidVideoWith400() async throws {
        let fixture = try await Self.fixture(mode: .auto)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let loop = fixture.loop, script = fixture.script
        try await loop.ensureModelLoaded(modelId: Self.modelID, allowEviction: false,
                                         revisionDirectory: fixture.directory)
        let held = await fixture.budget.reservationBytesSnapshot()
        let recorder = Recorder(), consumer = NodeKeyPair.generate()
        let long = Array(repeating: "a", count: 300)
        let second = Box<(sse: String, terminal: OutboundMessage)>()
        let first = try await Self.send(Self.imageBody(long, script: script, maxTokens: 300), to: loop,
                                        recorder: recorder, consumer: consumer) { id in
            while recorder.chunks(id).count < 3 { try? await Task.sleep(for: .milliseconds(1)) }
            if let body = try? Self.imageBody(nil, script: script, maxTokens: 2),
               let result = try? await Self.send(body, to: loop, recorder: recorder, consumer: consumer) {
                second.set(result)
            }
        }
        #expect(Self.usage(first.terminal)?.completionTokens == 300, "\(first.terminal)")
        let refused = try #require(second.value)
        #expect(Self.failure(refused.terminal)?.statusCode == 429, "\(refused.terminal)")
        #expect(refused.sse.isEmpty)
        #expect(await fixture.budget.reservationBytesSnapshot() == held)
        let video = try JSONSerialization.data(withJSONObject: ["model": Self.modelID, "stream": true,
            "max_tokens": 2, "messages": [["role": "user", "content": [
                ["type": "video_url", "video_url": ["url": "data:video/mp4;base64,AAAAIGZ0eXBpc29t"]],
                ["type": "text", "text": "Describe."]]]]])
        let videoAnswer = try await Self.send(video, to: loop, recorder: recorder, consumer: consumer)
        #expect(Self.failure(videoAnswer.terminal)?.statusCode == 400, "\(videoAnswer.terminal)")
        #expect(await fixture.budget.reservationBytesSnapshot() == held)
        #expect(await loop.unloadModel(Self.modelID))
    }
}
