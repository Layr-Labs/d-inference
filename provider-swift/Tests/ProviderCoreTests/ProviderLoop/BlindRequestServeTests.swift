import CryptoKit
import Foundation
import Testing

@testable import ProviderCore

#if DEBUG
/// Blind requests as `ProviderLoop.run()` serves them against a mock
/// coordinator: a body the client sealed to this Mac, relayed unopened under
/// the coordinator's signed terms, served within them or refused with a
/// refusal this Mac signs.
@Suite("Blind requests in the serve loop", .serialized)
struct BlindRequestServeTests {
    static func posture(coreDumpsDisabled: Bool = true) -> SecurityPosture {
        SecurityPosture(
            sipEnabled: true, rdmaDisabled: true, secureBootEnabled: true,
            authenticatedRootEnabled: true, hardenedRuntimeEnabled: true, antiDebugEnabled: true,
            coreDumpsDisabled: coreDumpsDisabled, envScrubbed: true, bundleSignatureValid: true,
            binaryHash: String(repeating: "a", count: 64),
            bootSecurity: BootSecuritySnapshot(
                macOSMajorVersion: 27, sip: .enabled, sipConfiguration: SIPConfiguration(rawValue: 0),
                secureBoot: .full, authenticatedRoot: true))
    }

    /// A running loop that pins the fixture's signing key, in a posture that holds.
    static func serving(posture: SecurityPosture = posture()) async throws -> (ServeLoopFixture, Task<Void, Error>) {
        let fixture = try await ServeLoopFixture.make()
        await fixture.loop.setBlindRequestPinsForTesting([BlindRequestFixture.pin])
        await fixture.loop.setSecurityPostureForTesting(posture)
        let task = fixture.start()
        _ = try await fixture.awaitRegistration()
        return (fixture, task)
    }

    @Test("a provider that pins a key and holds its posture registers blind serving")
    func registration() async throws {
        let (fixture, task) = try await Self.serving()
        let frame = try #require(fixture.mock.snapshot().registerFrames.first)
        let object = try #require(try JSONSerialization.jsonObject(with: frame) as? [String: Any])
        #expect(object["blind_protocol"] as? Int == 1)
        let signing = try #require(object["request_signing"] as? [String: Any])
        let keys = try #require(signing["keys"] as? [[String: Any]])
        #expect(keys.count == 1)
        #expect(keys.first?["kid"] as? String == BlindRequestFixture.pin.keyID)
        #expect(signing["require_signature"] == nil)
        #expect(await fixture.stop(task))
    }

    @Test("a provider whose posture does not hold registers no blind serving")
    func noRegistrationWithoutPosture() async throws {
        let (fixture, task) = try await Self.serving(posture: Self.posture(coreDumpsDisabled: false))
        let frame = try #require(fixture.mock.snapshot().registerFrames.first)
        let object = try #require(try JSONSerialization.jsonObject(with: frame) as? [String: Any])
        #expect(object["blind_protocol"] == nil)
        #expect(object["request_signing"] == nil)
        #expect(await fixture.stop(task))
    }

    @Test("a request within its terms is served, generating at most the signed output bound",
          arguments: [nil, 16] as [Int?])
    func servedWithinTerms(bodyMaxTokens: Int?) async throws {
        let (fixture, task) = try await Self.serving()
        let recipient = await fixture.loop.keyPair.publicKeyBytes
        var request = BlindRequestFixture()
        if let bodyMaxTokens { request.bodyFields = [#""max_tokens":\#(bodyMaxTokens)"#] }
        let requestID = request.requestID
        try await fixture.mock.pushInferenceRequest(try request.frame(recipient: recipient))
        try await fixture.awaitSubmissions(1)
        #expect(fixture.engine.submittedMaxTokens == [bodyMaxTokens ?? request.maxTokens])
        fixture.completeSubmission(0)

        let done = try await fixture.mock.waitForSnapshot(timeout: .seconds(10)) {
            ServeLoopFixture.terminalCount($0, requestId: requestID) > 0
        }
        let snapshot = try #require(done)
        let complete = try #require(snapshot.inferenceComplete.first { $0.requestId == requestID })
        let sealed = try #require(complete.encryptedUsage)
        let opened = try #require(
            try JSONSerialization.jsonObject(with: request.client.decryptPayload(sealed)) as? [String: Any])
        #expect(opened["chunk_count"] as? Int == snapshot.inferenceChunks.filter { $0.requestId == requestID }.count)
        #expect(await fixture.stop(task))
    }

    @Test("a refused request gets a refusal this Mac signs, naming its reason")
    func refusals() async throws {
        let (fixture, task) = try await Self.serving()
        let recipient = await fixture.loop.keyPair.publicKeyBytes
        let other = NodeKeyPair.generate().publicKeyBytes
        typealias Case = (name: String, reason: BlindRefusalReason, verified: Bool,
                          frame: () throws -> CoordinatorMessage.InferenceRequest)
        func request(_ change: (inout BlindRequestFixture) -> Void) -> BlindRequestFixture {
            var request = BlindRequestFixture()
            change(&request)
            return request
        }
        let cases: [Case] = [
            ("an unverifiable signature", .signatureInvalid, false, {
                let request = BlindRequestFixture()
                let jws = try request.signedRequest(recipient: recipient, ciphertext: Data(count: 64))
                return try request.frame(recipient: recipient, signedRequest: jws)
            }),
            ("terms of another version", .unsupportedVersion, true, {
                try BlindRequestFixture().frame(recipient: recipient, member: BlindFrameMember(version: 2, meta: Data("{}".utf8)))
            }),
            ("a seal set without this Mac", .notInSet, true, {
                try BlindRequestFixture().frame(recipient: recipient, sealSet: [other])
            }),
            ("meta other than the signed meta", .metaMismatch, true, {
                try BlindRequestFixture().frame(recipient: recipient, member: BlindFrameMember(version: 1, meta: Data("{}".utf8)))
            }),
            ("terms naming a client key other than the frame's sender", .bindingMismatch, true, {
                try request { $0.termsClientKey = other }.frame(recipient: recipient)
            }),
            ("an all-zero sender key", .sealUnopenable, true, {
                try request { $0.senderKey = Data(count: 32) }.frame(recipient: recipient)
            }),
            ("a sender key of small order", .sealUnopenable, true, {
                try request { $0.senderKey = Data([1] + [UInt8](repeating: 0, count: 31)) }.frame(recipient: recipient)
            }),
            ("a body sealed to another key", .sealUnopenable, true, {
                try BlindRequestFixture().frame(recipient: recipient, sealedTo: other)
            }),
            ("a body without its binding", .bindingMissing, true, {
                try request { $0.sealedBinding = .some(nil) }.frame(recipient: recipient)
            }),
            ("a binding to another nonce", .bindingMismatch, true, {
                try request {
                    $0.sealedBinding = #"{"v":1,"meta_sha256":"\#($0.metaSHA256)","nonce":"other","cred":"\#($0.cred)","ts":\#($0.clientTs)}"#
                }.frame(recipient: recipient)
            }),
            ("a cache salt shorter than 16 bytes", .bindingMismatch, true, {
                try request {
                    $0.sealedBinding = #"{"v":1,"meta_sha256":"\#($0.metaSHA256)","nonce":"\#($0.nonce)","cred":"\#($0.cred)","ts":\#($0.clientTs),"cache_salt":"AAAA"}"#
                }.frame(recipient: recipient)
            }),
            ("a client clock eleven minutes behind", .stale, true, {
                try request { $0.clientTs -= 660_000 }.frame(recipient: recipient)
            }),
            ("a body naming another model", .modelMismatch, true, {
                try request { $0.bodyModel = "other/model" }.frame(recipient: recipient)
            }),
            ("a body asking for more than the output bound", .boundExceeded, true, {
                try request { $0.bodyFields = [#""max_tokens":128"#] }.frame(recipient: recipient)
            }),
            ("max_completion_tokens over the output bound", .boundExceeded, true, {
                try request { $0.bodyFields = [#""max_completion_tokens":65"#] }.frame(recipient: recipient)
            }),
            ("tools the terms do not declare", .traitsMismatch, true, {
                try request {
                    $0.bodyFields = [#""tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{}}}}]"#]
                }.frame(recipient: recipient)
            }),
            ("a media part the terms do not declare", .traitsMismatch, true, {
                try request {
                    $0.messages = #"[{"role":"user","content":[{"type":"text","text":"x"},{"type":"image_url","image_url":{"url":"data:image/png;base64,iVBORw0KGgo="}}]}]"#
                }.frame(recipient: recipient)
            }),
            ("a body that is not a chat request", .bindingMissing, true, {
                try request { $0.bodyFields = [#""temperature":"warm""#] }.frame(recipient: recipient)
            }),
            ("a prompt over its signed bound", .promptBoundExceeded, true, {
                try request { $0.promptTokenBound = 2 }.frame(recipient: recipient)
            }),
        ]
        for testCase in cases {
            let frame = try testCase.frame()
            let error = try await Self.terminalError(fixture, frame)
            #expect(error.failureCode == .blindRefused, "\(testCase.name)")
            #expect(error.statusCode == testCase.reason.statusCode, "\(testCase.name)")
            let refusal = try #require(error.blindRefusal, "\(testCase.name)")
            #expect(refusal.statement["reason"] == .text(testCase.reason.rawValue), "\(testCase.name)")
            #expect(refusal.statement["request_id"] == .text(frame.requestId), "\(testCase.name)")
            let jws = try #require(frame.blind?.signedRequest)
            let digest = testCase.verified ? BlindRequestFixture.digest(of: jws) : ""
            #expect(refusal.statement["signed_request_sha256"] == .text(digest), "\(testCase.name)")
            #expect(try BlindRequestFixture.refusalVerifies(refusal, publicKeyBase64: fixture.signer.publicKeyBase64),
                    "\(testCase.name)")
        }
        #expect(fixture.engine.ordinarySubmissionCount == 0)
        #expect(await fixture.stop(task))
    }

    @Test("the engine gets the signed scope narrowed by the client's salt, never the frame's clear scope")
    func signedScopeReachesTheEngine() async throws {
        let (fixture, task) = try await Self.serving()
        let recipient = await fixture.loop.keyPair.publicKeyBytes
        let salt = Data(repeating: 7, count: 16)
        var salted = BlindRequestFixture()
        salted.sealedBinding = #"{"v":1,"meta_sha256":"\#(salted.metaSHA256)","nonce":"\#(salted.nonce)","cred":"\#(salted.cred)","ts":\#(salted.clientTs),"cache_salt":"\#(CoordinatorRequestJWS.base64URL(salt))"}"#
        var unscoped = BlindRequestFixture()
        unscoped.cacheScope = nil
        for (index, request) in [salted, unscoped].enumerated() {
            try await fixture.mock.pushInferenceRequest(
                try request.frame(recipient: recipient, clearCacheScope: "clear-frame-scope"))
            try await fixture.awaitSubmissions(index + 1)
            fixture.completeSubmission(index)
            let requestID = request.requestID
            _ = try await fixture.mock.waitForSnapshot(timeout: .seconds(10)) {
                ServeLoopFixture.terminalCount($0, requestId: requestID) > 0
            }
        }
        let expected = BlindBodyCheck.cacheScope(signed: salted.cacheScope, salt: salt)
        #expect(expected?.hasPrefix("blind-v1:account-scope|s:") == true)
        #expect(fixture.engine.submittedCacheSalts == [expected, nil])
        #expect(await fixture.stop(task))
    }

    @Test("a client nonce is served once")
    func replayedNonce() async throws {
        let (fixture, task) = try await Self.serving()
        let recipient = await fixture.loop.keyPair.publicKeyBytes
        let first = BlindRequestFixture()
        try await fixture.mock.pushInferenceRequest(try first.frame(recipient: recipient))
        try await fixture.awaitSubmissions(1)
        fixture.completeSubmission(0)

        var second = BlindRequestFixture()
        second.nonce = first.nonce
        let error = try await Self.terminalError(fixture, try second.frame(recipient: recipient))
        #expect(error.blindRefusal?.statement["reason"] == .text("replayed"))
        #expect(fixture.engine.ordinarySubmissionCount == 1)
        #expect(await fixture.stop(task))
    }

    @Test("a repeat of a signed frame already received gets no answer")
    func repeatedFrame() async throws {
        let (fixture, task) = try await Self.serving()
        let recipient = await fixture.loop.keyPair.publicKeyBytes
        let request = BlindRequestFixture()
        let frame = try request.frame(recipient: recipient)
        try await fixture.mock.pushInferenceRequest(frame)
        try await fixture.awaitSubmissions(1)
        try await fixture.mock.pushInferenceRequest(frame)
        try await Task.sleep(for: .milliseconds(200))
        fixture.completeSubmission(0)
        let requestID = request.requestID
        let done = try await fixture.mock.waitForSnapshot(timeout: .seconds(10)) {
            ServeLoopFixture.terminalCount($0, requestId: requestID) > 0
        }
        let snapshot = try #require(done)
        try await Task.sleep(for: .milliseconds(200))
        #expect(ServeLoopFixture.terminalCount(fixture.mock.snapshot(), requestId: request.requestID) == 1)
        #expect(snapshot.inferenceComplete.contains { $0.requestId == request.requestID })
        #expect(fixture.engine.ordinarySubmissionCount == 1)
        #expect(await fixture.stop(task))
    }

    @Test("a Mac whose posture stopped holding refuses with posture, before opening the body")
    func postureRefusal() async throws {
        let (fixture, task) = try await Self.serving()
        await fixture.loop.setSecurityPostureForTesting(Self.posture(coreDumpsDisabled: false))
        let recipient = await fixture.loop.keyPair.publicKeyBytes
        let frame = try BlindRequestFixture().frame(recipient: recipient)
        let error = try await Self.terminalError(fixture, frame)
        #expect(error.statusCode == 502)
        let refusal = try #require(error.blindRefusal)
        #expect(refusal.statement["reason"] == .text("posture"))
        #expect(try BlindRequestFixture.refusalVerifies(refusal, publicKeyBase64: fixture.signer.publicKeyBase64))
        #expect(fixture.engine.ordinarySubmissionCount == 0)
        #expect(await fixture.stop(task))
    }

    /// Pushes `frame` and returns its one terminal, which must be an error.
    static func terminalError(
        _ fixture: ServeLoopFixture, _ frame: CoordinatorMessage.InferenceRequest
    ) async throws -> ProviderMessage.InferenceError {
        try await fixture.mock.pushInferenceRequest(frame)
        let done = try await fixture.mock.waitForSnapshot(timeout: .seconds(10)) {
            ServeLoopFixture.terminalCount($0, requestId: frame.requestId) > 0
        }
        let snapshot = try #require(done, "no terminal for \(frame.requestId)")
        #expect(!snapshot.inferenceComplete.contains { $0.requestId == frame.requestId })
        return try #require(snapshot.inferenceErrors.first { $0.requestId == frame.requestId })
    }
}
#endif
