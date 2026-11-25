// Copyright © 2026 Eigen Labs.

import Foundation
import Testing
@testable import ProviderCore

#if DEBUG
extension NemotronSuperManagedSlotTests {
    /// The managed Super owner serves the raw body, not the handler's request
    /// shape, so the signed output bound must reach it through the bridge: a
    /// blind body that names no limit generates the signed `max_tokens`, not
    /// the model's default.
    @Test(.timeLimit(.minutes(3)))
    func blindRequestOnTheManagedSlotGeneratesAtMostTheSignedBound() async throws {
        let signer = ServeLoopTestSigner()
        let fixture = try await Self.fixture(mode: .off, signer: signer)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let loop = fixture.loop
        try await loop.ensureModelLoaded(modelId: Self.modelID, allowEviction: false,
                                         revisionDirectory: fixture.directory)
        await loop.setBlindRequestPinsForTesting([BlindRequestFixture.pin])
        await loop.setSecurityPostureForTesting(BlindRequestServeTests.posture())
        fixture.script.set(Array(repeating: "a", count: 16))

        var request = BlindRequestFixture()
        request.model = Self.modelID
        request.bodyModel = Self.modelID
        request.maxTokens = 2
        request.defaultMembers = [#""temperature":0"#, #""chat_template_kwargs":{"enable_thinking":false}"#]
        let frame = try request.frame(recipient: await loop.keyPair.publicKeyBytes)
        let body = try #require(frame.encryptedBody)
        let ciphertext = try #require(Data(base64Encoded: body.ciphertext))
        let recorder = Recorder()
        await loop.handleInferenceRequest(requestId: frame.requestId, ciphertext: ciphertext,
            senderPublicKey: request.client.publicKeyBytes, cacheReceiptNonce: nil, authenticatedCacheScope: nil,
            blind: frame.blind, send: SendHandle(recorder.record))
        let deadline = ContinuousClock.now + .seconds(60)
        while recorder.terminal(frame.requestId) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let terminal = try #require(recorder.terminal(frame.requestId))
        let usage = try #require(Self.usage(terminal), "\(terminal)")
        #expect(usage.completionTokens == 2)
        #expect(await loop.unloadModel(Self.modelID))
    }
}
#endif
