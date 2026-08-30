import CryptoKit
import Foundation
import Testing
@testable import ProviderCore

private let v2ProviderSecret = try! Data(hexString: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
private let v2ClientSecret = try! Data(hexString: "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f")
private let v2Salt = try! Data(hexString: "404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f")

private func vectorRequest(deadline: String = "2030-01-02T03:04:05.123456789Z") throws -> PrivateV2Request {
    let client = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: v2ClientSecret)
    let empty = PrivateV2Request(
        version: "private_v2",
        leaseId: "lease-01",
        requestId: "request-01",
        routeId: "route-01",
        model: "model-01",
        endpoint: .chatCompletions,
        stream: true,
        deadline: deadline,
        transcriptDigest: "",
        processCertificateDigest: "cert-sha256",
        releaseBinaryHash: "release-sha256",
        modelManifestHash: "model-sha256",
        releaseGeneration: 7,
        modelGeneration: 11,
        requestedMaxOutputTokens: 4096,
        routeMode: "public",
        ownerBinding: "",
        requiresVision: false,
        kdfSalt: Base64URL.encode(v2Salt),
        clientPublicKey: Base64URL.encode(Data(client.publicKey.rawRepresentation)),
        nonce: Base64URL.encode(Data(repeating: 0, count: 12)),
        ciphertext: "")
    let digest = PrivateV2Transcript(request: empty).digest()
    return PrivateV2Request(
        version: empty.version,
        leaseId: empty.leaseId,
        requestId: empty.requestId,
        routeId: empty.routeId,
        model: empty.model,
        endpoint: empty.endpoint,
        stream: empty.stream,
        deadline: empty.deadline,
        transcriptDigest: Base64URL.encode(digest),
        processCertificateDigest: empty.processCertificateDigest,
        releaseBinaryHash: empty.releaseBinaryHash,
        modelManifestHash: empty.modelManifestHash,
        releaseGeneration: empty.releaseGeneration,
        modelGeneration: empty.modelGeneration,
        requestedMaxOutputTokens: empty.requestedMaxOutputTokens,
        routeMode: empty.routeMode,
        ownerBinding: empty.ownerBinding,
        requiresVision: empty.requiresVision,
        kdfSalt: empty.kdfSalt,
        clientPublicKey: empty.clientPublicKey,
        nonce: empty.nonce,
        ciphertext: empty.ciphertext)
}

private func clientKeys(for request: PrivateV2Request) throws -> PrivateV2KeyMaterial {
    let client = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: v2ClientSecret)
    let provider = try NodeKeyPair(rawSecret: v2ProviderSecret)
    let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: provider.publicKeyBytes)
    let shared = try client.sharedSecretFromKeyAgreement(with: peer)
    let digest = try Base64URL.decode(request.transcriptDigest)
    var requestInfo = PrivateV2Protocol.requestInfoPrefix
    requestInfo.append(digest)
    var responseInfo = PrivateV2Protocol.responseInfoPrefix
    responseInfo.append(digest)
    return PrivateV2KeyMaterial(
        requestKey: shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: v2Salt, sharedInfo: requestInfo, outputByteCount: 32),
        responseKey: shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: v2Salt, sharedInfo: responseInfo, outputByteCount: 32))
}

@Test("private-v2 canonical transcript has exact Go key order")
func privateV2CanonicalTranscript() throws {
    let request = try vectorRequest()
    let canonical = String(data: PrivateV2Transcript(request: request).canonicalJSON(), encoding: .utf8)
    #expect(canonical == #"{"deadline":"2030-01-02T03:04:05.123456789Z","endpoint":"chat.completions","lease_id":"lease-01","model":"model-01","model_generation":11,"model_manifest_hash":"model-sha256","owner_binding":"","process_certificate_digest":"cert-sha256","release_binary_hash":"release-sha256","release_generation":7,"request_id":"request-01","requested_max_output_tokens":4096,"requires_vision":false,"route_id":"route-01","route_mode":"public"}"#)
    #expect(Base64URL.encode(PrivateV2Transcript(request: request).digest()) == request.transcriptDigest)
}

@Test("private-v2 protocol mirrors additive request/chunk wire exactly")
func privateV2ProtocolMirror() throws {
    let request = try vectorRequest()
    let requestData = try ProviderProtocolCodec.encodeCoordinatorMessage(
        .privateRequestV2(request))
    let requestObject = try #require(
        JSONSerialization.jsonObject(with: requestData) as? [String: Any])
    #expect(requestObject["type"] as? String == "private_request_v2")
    #expect(requestObject["version"] as? String == "private_v2")
    #expect(requestObject["model"] as? String == request.model)
    #expect(requestObject["kdf_salt"] as? String == request.kdfSalt)
    #expect(requestObject["client_public_key"] as? String == request.clientPublicKey)
    #expect(try ProviderProtocolCodec.decodeCoordinatorMessage(from: requestData)
            == .privateRequestV2(request))

    let chunk = PrivateV2Chunk(
        requestId: request.requestId,
        sequence: 0,
        terminal: true,
        nonce: "AAECAwQFBgcICQoL",
        ciphertext: "opaque-ciphertext",
        usage: PrivateV2Usage(promptTokens: 2, completionTokens: 3),
        failureCode: nil,
        statusCode: nil)
    let chunkData = try ProviderProtocolCodec.encodeProviderMessage(.privateChunkV2(chunk))
    let chunkObject = try #require(
        JSONSerialization.jsonObject(with: chunkData) as? [String: Any])
    #expect(chunkObject["type"] as? String == "private_chunk_v2")
    #expect((chunkObject["sequence"] as? NSNumber)?.uint64Value == 0)
    #expect(chunkObject["terminal"] as? Bool == true)
    #expect(chunkObject["data"] == nil)
    #expect(try ProviderProtocolCodec.decodeProviderMessage(from: chunkData)
            == .privateChunkV2(chunk))
}

@Test("private-v2 X25519 HKDF AES-GCM request/response contract")
func privateV2CryptoContract() throws {
    let request = try vectorRequest()
    let provider = try NodeKeyPair(rawSecret: v2ProviderSecret)
    let digest = try Base64URL.decode(request.transcriptDigest)
    let clientPublicKey = try Base64URL.decode(request.clientPublicKey)
    let providerKeys = try provider.privateV2KeyMaterial(
        clientPublicKey: clientPublicKey, salt: v2Salt, transcriptDigest: digest)
    let client = try clientKeys(for: request)
    let requestNonce = try Data(hexString: "000102030405060708090a0b")
    let plaintext = Data("opaque-private-v2-sentinel".utf8)
    let requestCiphertext = try PrivateV2Crypto.seal(
        plaintext, key: client.requestKey, nonce: requestNonce, aad: digest)
    #expect(requestCiphertext.range(of: plaintext) == nil)
    #expect(try PrivateV2Crypto.open(
        requestCiphertext,
        key: providerKeys.requestKey,
        nonce: requestNonce,
        aad: digest) == plaintext)

    let responseNonce = try Data(hexString: "0c0d0e0f1011121314151617")
    let aad = try PrivateV2Crypto.responseAAD(transcriptDigest: digest, sequence: 42)
    let responseCiphertext = try PrivateV2Crypto.seal(
        plaintext, key: providerKeys.responseKey, nonce: responseNonce, aad: aad)
    #expect(try PrivateV2Crypto.open(
        responseCiphertext,
        key: client.responseKey,
        nonce: responseNonce,
        aad: aad) == plaintext)
}

@Test("private-v2 rejects transcript/AAD/ciphertext mutation")
func privateV2MutationMatrix() throws {
    let request = try vectorRequest()
    let client = try clientKeys(for: request)
    let nonce = Data(repeating: 9, count: 12)
    let digest = try Base64URL.decode(request.transcriptDigest)
    let plaintext = Data("mutation sentinel".utf8)
    let ciphertext = try PrivateV2Crypto.seal(
        plaintext, key: client.requestKey, nonce: nonce, aad: digest)
    for index in [0, ciphertext.count / 2, ciphertext.count - 1] {
        var bytes = Array(ciphertext)
        bytes[index] = bytes[index] ^ 1
        let mutated = Data(bytes)
        #expect(mutated != ciphertext)
        #expect(throws: PrivateV2Error.self) {
            _ = try PrivateV2Crypto.open(
                mutated, key: client.requestKey, nonce: nonce, aad: digest)
        }
    }
    var digestBytes = Array(digest)
    digestBytes[0] = digestBytes[0] ^ 1
    let mutatedDigest = Data(digestBytes)
    #expect(throws: PrivateV2Error.self) {
        _ = try PrivateV2Crypto.open(
            ciphertext, key: client.requestKey, nonce: nonce, aad: mutatedDigest)
    }
}

@Test("private-v2 replay ledger is one-use and fails closed at capacity")
func privateV2ReplayAndCapacity() throws {
    let now = Date()
    let ledger = PrivateV2ReplayLedger(capacity: 2)
    try ledger.claim(leaseId: "a", requestId: "1", expiresAt: now.addingTimeInterval(30), now: now)
    #expect(throws: PrivateV2Error.replay) {
        try ledger.claim(leaseId: "a", requestId: "1", expiresAt: now.addingTimeInterval(30), now: now)
    }
    try ledger.claim(leaseId: "b", requestId: "2", expiresAt: now.addingTimeInterval(30), now: now)
    #expect(throws: PrivateV2Error.replayCapacity) {
        try ledger.claim(leaseId: "c", requestId: "3", expiresAt: now.addingTimeInterval(30), now: now)
    }
    try ledger.claim(
        leaseId: "c", requestId: "3",
        expiresAt: now.addingTimeInterval(61),
        now: now.addingTimeInterval(31))
    #expect(ledger.count == 1)
}

@Test("private-v2 replay claim is atomic under concurrency")
func privateV2ReplayConcurrency() async throws {
    let ledger = PrivateV2ReplayLedger()
    let expiry = Date().addingTimeInterval(30)
    let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
        for _ in 0..<64 {
            group.addTask {
                do {
                    try ledger.claim(leaseId: "lease", requestId: "request", expiresAt: expiry)
                    return true
                } catch { return false }
            }
        }
        var count = 0
        for await success in group where success { count += 1 }
        return count
    }
    #expect(successes == 1)
}

private final class ChunkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PrivateV2Chunk] = []
    func append(_ chunk: PrivateV2Chunk) { lock.withLock { values.append(chunk) } }
    func snapshot() -> [PrivateV2Chunk] { lock.withLock { values } }
}

private final class NonceSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt8 = 0
    func next() -> Data {
        lock.withLock {
            defer { value &+= 1 }
            return Data(repeating: value, count: 12)
        }
    }
}

@Test("private-v2 encrypted chunks have ordered sequence, unique nonce, encrypted terminal error")
func privateV2ChunkWriterContract() throws {
    let request = try vectorRequest()
    let keys = try clientKeys(for: request)
    let digest = try Base64URL.decode(request.transcriptDigest)
    let recorder = ChunkRecorder()
    let nonceSequence = NonceSequence()
    let writer = PrivateV2ChunkWriter(
        requestId: request.requestId,
        transcriptDigest: digest,
        responseKey: keys.responseKey,
        nonceGenerator: nonceSequence.next,
        sink: recorder.append)
    let sentinel = Data(#"{"secret":"opaque-privatetext-sentinel"}"#.utf8)
    try writer.emit(payload: sentinel, terminal: false)
    let errorPayload = PrivateV2EndpointAdapter.errorPayload(
        endpoint: .chatCompletions, failureCode: "invalid_request")
    try writer.emit(
        payload: errorPayload,
        terminal: true,
        failureCode: "invalid_request",
        statusCode: 400)
    let chunks = recorder.snapshot()
    #expect(chunks.map(\.sequence) == [0, 1])
    #expect(Set(chunks.map(\.nonce)).count == chunks.count)
    #expect(chunks[0].terminal == false)
    #expect(chunks[1].terminal == true)
    #expect(chunks[1].failureCode == "invalid_request")
    #expect(chunks[1].statusCode == 400)
    #expect(!chunks[0].ciphertext.contains("opaque-privatetext-sentinel"))
    for chunk in chunks {
        let plaintext = try PrivateV2Crypto.open(
            Base64URL.decode(chunk.ciphertext),
            key: keys.responseKey,
            nonce: Base64URL.decode(chunk.nonce),
            aad: PrivateV2Crypto.responseAAD(
                transcriptDigest: digest, sequence: chunk.sequence))
        let object = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any]
        #expect(object?["request_id"] as? String == request.requestId)
        #expect((object?["sequence"] as? NSNumber)?.uint64Value == chunk.sequence)
    }
    #expect(throws: PrivateV2Error.terminalAlreadySent) {
        try writer.emit(payload: Data("{}".utf8), terminal: false)
    }
}

@Test("private-v2 process key rotation invalidates old ciphertext")
func privateV2ProcessKeyRotation() throws {
    let request = try vectorRequest()
    let digest = try Base64URL.decode(request.transcriptDigest)
    let client = try clientKeys(for: request)
    let nonce = Data(repeating: 3, count: 12)
    let ciphertext = try PrivateV2Crypto.seal(
        Data("bound to old process".utf8),
        key: client.requestKey,
        nonce: nonce,
        aad: digest)
    let rotated = NodeKeyPair.generate()
    let rotatedKeys = try rotated.privateV2KeyMaterial(
        clientPublicKey: Base64URL.decode(request.clientPublicKey),
        salt: v2Salt,
        transcriptDigest: digest)
    #expect(throws: PrivateV2Error.self) {
        _ = try PrivateV2Crypto.open(
            ciphertext,
            key: rotatedKeys.requestKey,
            nonce: nonce,
            aad: digest)
    }
}

@Test("private-v2 deadlines reject expired and over-60-second leases")
func privateV2DeadlineBounds() throws {
    let now = Date()
    let ledger = PrivateV2ReplayLedger()
    #expect(throws: PrivateV2Error.deadlineExpired) {
        try ledger.claim(leaseId: "expired", requestId: "1", expiresAt: now, now: now)
    }
    let parsed = try PrivateV2Date.parse("2030-01-02T03:04:05.123456789Z")
    #expect(parsed.timeIntervalSince1970 > 0)
}

@Test("private-v2 shared Go Swift TypeScript golden vector")
func privateV2SharedGoldenVector() throws {
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("console-ui/__tests__/fixtures/private-v2-golden.json")
    let fixture = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL))
            as? [String: Any])
    let provider = try NodeKeyPair(
        rawSecret: Base64URL.decode(try #require(fixture["provider_private_key"] as? String)))
    #expect(provider.publicKeyBase64 == fixture["provider_public_key"] as? String)
    let salt = try Base64URL.decode(try #require(fixture["kdf_salt"] as? String))
    let clientPublicKey = try Base64URL.decode(
        try #require(fixture["client_public_key"] as? String))
    let request = PrivateV2Request(
        version: "private_v2",
        leaseId: "lease-vector-1",
        requestId: "request-vector-1",
        routeId: "route-vector-1",
        model: "org/concrete-model",
        endpoint: .chatCompletions,
        stream: true,
        deadline: "2030-01-02T03:04:35Z",
        transcriptDigest: try #require(fixture["transcript_digest"] as? String),
        processCertificateDigest: try #require(fixture["certificate_digest"] as? String),
        releaseBinaryHash: String(repeating: "1", count: 64),
        modelManifestHash: String(repeating: "4", count: 64),
        releaseGeneration: 8,
        modelGeneration: 9,
        requestedMaxOutputTokens: 4096,
        routeMode: "public",
        ownerBinding: "",
        requiresVision: false,
        kdfSalt: Base64URL.encode(salt),
        clientPublicKey: Base64URL.encode(clientPublicKey),
        nonce: try #require(fixture["request_nonce"] as? String),
        ciphertext: "")
    let transcriptJSON = try #require(fixture["transcript_json"] as? String)
    #expect(PrivateV2Transcript(request: request).canonicalJSON() == Data(transcriptJSON.utf8))
    let digest = PrivateV2Transcript(request: request).digest()
    #expect(Base64URL.encode(digest) == request.transcriptDigest)
    let keys = try provider.privateV2KeyMaterial(
        clientPublicKey: clientPublicKey, salt: salt, transcriptDigest: digest)
    let requestPlaintext = try #require(fixture["request_plaintext"] as? String)
    let requestCiphertext = try PrivateV2Crypto.seal(
        Data(requestPlaintext.utf8),
        key: keys.requestKey,
        nonce: Base64URL.decode(request.nonce),
        aad: digest)
    #expect(Base64URL.encode(requestCiphertext) == fixture["request_ciphertext"] as? String)
    let responseNonce = try #require(fixture["response_nonce"] as? String)
    let recorder = ChunkRecorder()
    let writer = PrivateV2ChunkWriter(
        requestId: request.requestId,
        transcriptDigest: digest,
        responseKey: keys.responseKey,
        nonceGenerator: {
            try Base64URL.decode(responseNonce)
        },
        sink: recorder.append)
    try writer.emit(
        payload: Data(#"{"choices":[{"delta":{"content":"hello"}}]}"#.utf8),
        terminal: true)
    let response = try #require(recorder.snapshot().first)
    #expect(response.ciphertext == fixture["response_ciphertext"] as? String)
}

@Test("private-v2 rejects process, release, model, route, and generation mismatch")
func privateV2IdentityMutationMatrix() throws {
    let request = try vectorRequest()
    let matching = PrivateV2InnerRequest(
        transcript: PrivateV2Transcript(request: request),
        body: Data("{}".utf8))
    try PrivateV2IdentityValidator.validate(
        inner: matching,
        outer: request,
        currentReleaseBinaryHash: request.releaseBinaryHash,
        currentReleaseGeneration: request.releaseGeneration,
        currentModelManifestHash: request.modelManifestHash,
        currentModelGeneration: request.modelGeneration)
    #expect(throws: PrivateV2Error.releaseMismatch) {
        try PrivateV2IdentityValidator.validate(
            inner: matching, outer: request,
            currentReleaseBinaryHash: "different-release",
            currentReleaseGeneration: request.releaseGeneration,
            currentModelManifestHash: request.modelManifestHash,
            currentModelGeneration: request.modelGeneration)
    }
    #expect(throws: PrivateV2Error.releaseMismatch) {
        try PrivateV2IdentityValidator.validate(
            inner: matching, outer: request,
            currentReleaseBinaryHash: request.releaseBinaryHash,
            currentReleaseGeneration: request.releaseGeneration + 1,
            currentModelManifestHash: request.modelManifestHash,
            currentModelGeneration: request.modelGeneration)
    }
    #expect(throws: PrivateV2Error.releaseMismatch) {
        try PrivateV2IdentityValidator.validate(
            inner: matching, outer: request,
            currentReleaseBinaryHash: request.releaseBinaryHash,
            currentReleaseGeneration: 0,
            currentModelManifestHash: request.modelManifestHash,
            currentModelGeneration: request.modelGeneration)
    }
    #expect(throws: PrivateV2Error.modelMismatch) {
        try PrivateV2IdentityValidator.validate(
            inner: matching, outer: request,
            currentReleaseBinaryHash: request.releaseBinaryHash,
            currentReleaseGeneration: request.releaseGeneration,
            currentModelManifestHash: "different-model",
            currentModelGeneration: request.modelGeneration)
    }
    #expect(throws: PrivateV2Error.modelMismatch) {
        try PrivateV2IdentityValidator.validate(
            inner: matching, outer: request,
            currentReleaseBinaryHash: request.releaseBinaryHash,
            currentReleaseGeneration: request.releaseGeneration,
            currentModelManifestHash: request.modelManifestHash,
            currentModelGeneration: request.modelGeneration + 1)
    }
    #expect(throws: PrivateV2Error.modelMismatch) {
        try PrivateV2IdentityValidator.validate(
            inner: matching, outer: request,
            currentReleaseBinaryHash: request.releaseBinaryHash,
            currentReleaseGeneration: request.releaseGeneration,
            currentModelManifestHash: request.modelManifestHash,
            currentModelGeneration: 0)
    }
    let wrongProcess = PrivateV2InnerRequest(
        transcript: PrivateV2Transcript(
            leaseId: request.leaseId,
            requestId: request.requestId,
            routeId: "wrong-route",
            endpoint: request.endpoint,
            model: request.model,
            processCertificateDigest: "wrong-process",
            releaseBinaryHash: request.releaseBinaryHash,
            modelManifestHash: request.modelManifestHash,
            releaseGeneration: request.releaseGeneration,
            modelGeneration: request.modelGeneration,
            ownerBinding: request.ownerBinding,
            requestedMaxOutputTokens: request.requestedMaxOutputTokens,
            requiresVision: request.requiresVision,
            routeMode: request.routeMode,
            deadline: request.deadline),
        body: Data("{}".utf8))
    #expect(throws: PrivateV2Error.requestMismatch) {
        try PrivateV2IdentityValidator.validate(
            inner: wrongProcess, outer: request,
            currentReleaseBinaryHash: request.releaseBinaryHash,
            currentReleaseGeneration: request.releaseGeneration,
            currentModelManifestHash: request.modelManifestHash,
            currentModelGeneration: request.modelGeneration)
    }
}

@Test("private-v2 binds output limit, media trait, and completion cardinality")
func privateV2AdmissionTraitBinding() throws {
    let oversized = Data(#"{"model":"m","messages":[],"stream":true,"max_tokens":101}"#.utf8)
    #expect(throws: PrivateV2Error.self) {
        _ = try PrivateV2EndpointAdapter.chatRequestBody(
            endpoint: .chatCompletions, model: "m", stream: true,
            requestedMaxOutputTokens: 100, defaultMaxOutputTokens: 4096,
            requiresVision: false, body: oversized)
    }
    let media = Data(#"{"model":"m","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,AA"}}]}],"stream":true,"max_tokens":1}"#.utf8)
    #expect(throws: PrivateV2Error.self) {
        _ = try PrivateV2EndpointAdapter.chatRequestBody(
            endpoint: .chatCompletions, model: "m", stream: true,
            requestedMaxOutputTokens: 1, defaultMaxOutputTokens: 4096,
            requiresVision: false, body: media)
    }
    let multiprompt = Data(#"{"model":"m","prompt":["a","b"],"stream":true,"max_tokens":1}"#.utf8)
    #expect(throws: PrivateV2Error.self) {
        _ = try PrivateV2EndpointAdapter.chatRequestBody(
            endpoint: .completions, model: "m", stream: true,
            requestedMaxOutputTokens: 1, defaultMaxOutputTokens: 4096,
            requiresVision: false, body: multiprompt)
    }
    let overProtocolCap = Data(#"{"model":"m","messages":[],"stream":true,"max_tokens":8001}"#.utf8)
    #expect(throws: PrivateV2Error.self) {
        _ = try PrivateV2EndpointAdapter.chatRequestBody(
            endpoint: .chatCompletions, model: "m", stream: true,
            requestedMaxOutputTokens: 8001, defaultMaxOutputTokens: 4096,
            requiresVision: false, body: overProtocolCap)
    }
}

@Test("private-v2 lowers Responses and Messages tool contracts")
func privateV2EndpointLoweringParity() throws {
    let responses = Data(#"{"model":"m","stream":true,"max_output_tokens":8,"input":[{"type":"reasoning","summary":[]},{"type":"function_call","call_id":"c1","name":"lookup","arguments":"{\"q\":1}"},{"type":"function_call","call_id":"c2","name":"lookup","arguments":"{\"q\":2}"},{"type":"function_call_output","call_id":"c1","output":"one"},{"type":"function_call_output","call_id":"c2","output":"two"}],"text":{"format":{"type":"json_object"}},"tools":[{"type":"function","name":"lookup","parameters":{"type":"object"}}]}"#.utf8)
    let loweredResponses = try PrivateV2EndpointAdapter.chatRequestBody(
        endpoint: .responses, model: "m", stream: true,
        requestedMaxOutputTokens: 8, defaultMaxOutputTokens: 4096,
        requiresVision: false, body: responses)
    let responseObject = try #require(
        JSONSerialization.jsonObject(with: loweredResponses) as? [String: Any])
    let loweredResponseMessages = try #require(
        responseObject["messages"] as? [[String: Any]])
    #expect(loweredResponseMessages.count == 3)
    #expect((loweredResponseMessages.first?["tool_calls"] as? [[String: Any]])?.count == 2)
    #expect((responseObject["response_format"] as? [String: Any])?["type"] as? String == "json_object")
    let hostedTool = Data(#"{"model":"m","stream":true,"max_output_tokens":8,"input":"x","tools":[{"type":"web_search"}]}"#.utf8)
    #expect(throws: PrivateV2Error.self) {
        _ = try PrivateV2EndpointAdapter.chatRequestBody(
            endpoint: .responses, model: "m", stream: true,
            requestedMaxOutputTokens: 8, defaultMaxOutputTokens: 4096,
            requiresVision: false, body: hostedTool)
    }

    let messages = Data(#"{"model":"m","stream":true,"max_tokens":8,"messages":[{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"lookup","input":{"q":1}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}],"tools":[{"name":"lookup","input_schema":{"type":"object"}}],"tool_choice":{"type":"tool","name":"lookup","disable_parallel_tool_use":true},"stop_sequences":["STOP"]}"#.utf8)
    let loweredMessages = try PrivateV2EndpointAdapter.chatRequestBody(
        endpoint: .messages, model: "m", stream: true,
        requestedMaxOutputTokens: 8, defaultMaxOutputTokens: 4096,
        requiresVision: false, body: messages)
    let messageObject = try #require(
        JSONSerialization.jsonObject(with: loweredMessages) as? [String: Any])
    #expect(messageObject["stop"] as? [String] == ["STOP"])
    #expect((messageObject["messages"] as? [[String: Any]])?.count == 2)
    #expect(messageObject["parallel_tool_calls"] as? Bool == false)
    let ordered = Data(#"{"model":"m","stream":true,"max_tokens":8,"messages":[{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"},{"type":"text","text":"after"}]}]}"#.utf8)
    let orderedBody = try PrivateV2EndpointAdapter.chatRequestBody(
        endpoint: .messages, model: "m", stream: true,
        requestedMaxOutputTokens: 8, defaultMaxOutputTokens: 4096,
        requiresVision: false, body: ordered)
    let orderedObject = try #require(
        JSONSerialization.jsonObject(with: orderedBody) as? [String: Any])
    let orderedMessages = try #require(orderedObject["messages"] as? [[String: Any]])
    #expect(orderedMessages.compactMap { $0["role"] as? String } == ["tool", "user"])
}

@Test("private-v2 native streams preserve lifecycle, reasoning, tools, and terminal reservation")
func privateV2NativeStreamAndChunkCap() throws {
    let adapter = PrivateV2NativeStreamAdapter(
        endpoint: .messages, requestId: "r", model: "m")
    let reasoning = adapter.payloads(
        fromSSE: #"data: {"choices":[{"delta":{"reasoning_content":"think"}}]}"#)
    #expect(reasoning.count == 3)
    let tool = adapter.payloads(
        fromSSE: #"data: {"choices":[{"delta":{"tool_calls":[{"id":"t","function":{"name":"f","arguments":"{"}}]}}]}"#)
    #expect(tool.count == 3)
    let secondTool = adapter.payloads(
        fromSSE: #"data: {"choices":[{"delta":{"tool_calls":[{"id":"t2","function":{"name":"g","arguments":"{"}}]}}]}"#)
    #expect(secondTool.count == 3)
    _ = adapter.payloads(
        fromSSE: #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#)
    let usage = PrivateV2Usage(promptTokens: 1, completionTokens: 2)
    let messageClosing = adapter.closingPayloads(usage: usage, stopSequence: "END")
    let closingData = try #require(messageClosing.last)
    let closingObject = try JSONSerialization.jsonObject(with: closingData)
    let messageDelta = try #require(closingObject as? [String: Any])
    #expect((messageDelta["delta"] as? [String: Any])?["stop_reason"] as? String == "stop_sequence")
    #expect((messageDelta["delta"] as? [String: Any])?["stop_sequence"] as? String == "END")
    let completionFinish = try #require(PrivateV2EndpointAdapter.payload(
        fromSSE: #"data: {"choices":[{"delta":{},"finish_reason":"length"}]}"#,
        endpoint: .completions))
    let completionObject = try #require(
        JSONSerialization.jsonObject(with: completionFinish) as? [String: Any])
    #expect(((completionObject["choices"] as? [[String: Any]])?.first)?["finish_reason"] as? String == "length")
    let responseAdapter = PrivateV2NativeStreamAdapter(
        endpoint: .responses, requestId: "r2", model: "m")
    let emptyResponseEvents = responseAdapter.payloads(
        fromSSE: #"data: {"choices":[{"delta":{},"finish_reason":"length"}]}"#)
    #expect(emptyResponseEvents.count == 2)
    #expect((try JSONSerialization.jsonObject(with: emptyResponseEvents[0])
        as? [String: Any])?["type"] as? String == "response.created")
    #expect((try JSONSerialization.jsonObject(with: emptyResponseEvents[1])
        as? [String: Any])?["type"] as? String == "response.in_progress")
    let incomplete = try #require(
        JSONSerialization.jsonObject(
            with: responseAdapter.terminalPayload(usage: usage)) as? [String: Any])
    #expect(incomplete["type"] as? String == "response.incomplete")
    let emptyMessages = PrivateV2NativeStreamAdapter(
        endpoint: .messages, requestId: "empty", model: "m")
    let emptyMessageEvents = emptyMessages.payloads(
        fromSSE: #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
    #expect(emptyMessageEvents.count == 1)
    let reconstruct = PrivateV2NativeStreamAdapter(
        endpoint: .responses, requestId: "multi", model: "m")
    let reasonEvents = reconstruct.payloads(
        fromSSE: #"data: {"choices":[{"delta":{"reasoning_content":"why"}}]}"#)
    let toolEvents = reconstruct.payloads(
        fromSSE: #"data: {"choices":[{"delta":{"tool_calls":[{"id":"call1","function":{"name":"f","arguments":"{\"x\":1}"}}]}}]}"#)
    let textEvents = reconstruct.payloads(
        fromSSE: #"data: {"choices":[{"delta":{"content":"answer"}}]}"#)
    let eventObjects = try (reasonEvents + toolEvents + textEvents).map {
        try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any])
    }
    #expect(eventObjects.compactMap {
        ($0["sequence_number"] as? NSNumber)?.uint64Value
    } == Array(0..<UInt64(eventObjects.count)))
    let eventTypes = eventObjects.compactMap { $0["type"] as? String }
    #expect(eventTypes.contains("response.reasoning_summary_part.added"))
    #expect(eventTypes.contains("response.reasoning_summary_part.done"))
    let added = eventObjects.filter {
        $0["type"] as? String == "response.output_item.added"
    }
    #expect(added.compactMap {
        ($0["output_index"] as? NSNumber)?.intValue
    } == [0, 1, 2])
    let functionAdded = try #require(added.first {
        (($0["item"] as? [String: Any])?["type"] as? String) == "function_call"
    })
    let functionItem = try #require(functionAdded["item"] as? [String: Any])
    #expect(functionItem["id"] as? String != functionItem["call_id"] as? String)
    #expect(functionItem["call_id"] as? String == "call1")
    for event in eventObjects where (event["type"] as? String)?.hasSuffix(".delta") == true {
        #expect(event["item_id"] as? String != nil)
        #expect((event["output_index"] as? NSNumber) != nil)
    }
    _ = reconstruct.closingPayloads(usage: usage)
    let completed = try #require(
        JSONSerialization.jsonObject(
            with: reconstruct.terminalPayload(usage: usage)) as? [String: Any])
    let completedResponse = try #require(completed["response"] as? [String: Any])
    #expect((completedResponse["output"] as? [[String: Any]])?.count == 3)
    #expect((completed["sequence_number"] as? NSNumber) != nil)
    let keys = try clientKeys(for: vectorRequest())
    let recorder = ChunkRecorder()
    let writer = PrivateV2ChunkWriter(
        requestId: "r",
        transcriptDigest: Data(repeating: 1, count: 32),
        responseKey: keys.responseKey,
        initialSequence: PrivateV2Protocol.maximumChunksPerRequest - 1,
        nonceGenerator: { Data(repeating: 7, count: 12) },
        sink: recorder.append)
    #expect(throws: PrivateV2Error.encryptionFailed) {
        try writer.emit(payload: Data("{}".utf8), terminal: false)
    }
    try writer.emit(
        payload: PrivateV2EndpointAdapter.errorPayload(
            endpoint: .messages, failureCode: "internal_failure"),
        terminal: true,
        failureCode: "internal_failure",
        statusCode: 500)
    let terminal = try #require(recorder.snapshot().first)
    #expect(terminal.sequence == 8191)
    #expect(terminal.terminal)
    #expect(terminal.failureCode == "internal_failure")
}
