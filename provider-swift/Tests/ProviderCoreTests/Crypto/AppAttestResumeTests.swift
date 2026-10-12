import CryptoKit
import Foundation
import Testing
@testable import ProviderCore

@Suite struct AppAttestResumeTests {
    @Test func sharedGoFixtureAndFreshResponseNonce() throws {
        let fixture = try AppAttestResumeFixture()
        let provider = try fixture.provider
        #expect(provider.publicKeyBase64 == fixture.providerPublicKey)
        #expect(try fixture.server.publicKeyBase64 == fixture.serverPublicKey)
        #expect(try provider.decryptPayload(fixture.challenge.encryptedChallenge) == Data(fixture.requestJson.utf8))
        let first = try provider.appAttestResumeResponse(to: fixture.challenge,
            clientNonce: AppAttestResumeFixture.nonce, now: AppAttestResumeFixture.now)
        let second = try provider.appAttestResumeResponse(to: fixture.challenge,
            clientNonce: AppAttestResumeFixture.nonce, now: AppAttestResumeFixture.now)
        let expected = try Data(hexString: fixture.responsePlaintextHex)
        #expect(try fixture.open(first) == expected)
        #expect(try fixture.open(second) == expected)
        #expect(try fixture.open(.init(id: first.id, ciphertext: fixture.responseCiphertext)) == expected)
        #expect(first.ciphertext != second.ciphertext)
        #expect(first.id == AppAttestResumeFixture.id)
    }

    @Test func responseCommitsExactDecryptedBytes() throws {
        let fixture = try AppAttestResumeFixture()
        let changed = " \n" + fixture.requestJson + "\t"
        let response = try fixture.provider.appAttestResumeResponse(to: fixture.seal(changed),
            clientNonce: AppAttestResumeFixture.nonce, now: AppAttestResumeFixture.now)
        var expected = Data("darkbloom.app-attest.endpoint-resume.response.v1\0".utf8)
        expected.append(contentsOf: SHA256.hash(data: Data(changed.utf8)))
        #expect(try fixture.open(response) == expected)
        #expect(try fixture.open(response) != Data(hexString: fixture.responsePlaintextHex))
    }

    @Test func rejectsMalformedBoxAndCiphertextReflection() throws {
        let fixture = try AppAttestResumeFixture()
        var tampered = try #require(Data(base64Encoded: fixture.requestCiphertext))
        tampered[tampered.count - 1] ^= 1
        for encrypted in [
            EncryptedPayload(ephemeralPublicKey: fixture.serverPublicKey, ciphertext: tampered.base64EncodedString()),
            EncryptedPayload(ephemeralPublicKey: fixture.serverPublicKey, ciphertext: fixture.responseCiphertext),
            EncryptedPayload(ephemeralPublicKey: fixture.serverPublicKey, ciphertext: Data(repeating: 0, count: 39).base64EncodedString()),
            EncryptedPayload(ephemeralPublicKey: fixture.serverPublicKey, ciphertext: fixture.requestCiphertext + "\n"),
            EncryptedPayload(ephemeralPublicKey: Data(repeating: 0, count: 31).base64EncodedString(), ciphertext: fixture.requestCiphertext),
            EncryptedPayload(ephemeralPublicKey: Data(repeating: 0, count: 32).base64EncodedString(), ciphertext: fixture.requestCiphertext),
        ] {
            #expect(throws: (any Error).self) {
                try fixture.provider.appAttestResumeResponse(to: .init(id: AppAttestResumeFixture.id, encryptedChallenge: encrypted),
                    clientNonce: AppAttestResumeFixture.nonce, now: AppAttestResumeFixture.now)
            }
        }
    }

    @Test func rejectsReflectionWrongEndpointNonceAndNewProcess() throws {
        let fixture = try AppAttestResumeFixture()
        let replacement = NodeKeyPair.generate()
        for (challenge, nonce, provider) in [
            (fixture.challenge, Data(repeating: 9, count: 32).base64EncodedString(), try fixture.provider),
            (fixture.challenge, AppAttestResumeFixture.nonce, replacement),
            (try fixture.seal(fixture.requestJson, to: replacement), AppAttestResumeFixture.nonce, replacement),
            (try fixture.seal(fixture.request(overrides: ["endpoint": replacement.publicKeyBase64])),
                AppAttestResumeFixture.nonce, try fixture.provider),
            (try fixture.seal(fixture.requestJson, id: Data(repeating: 8, count: 32).base64EncodedString()),
                AppAttestResumeFixture.nonce, try fixture.provider),
            (try fixture.seal(String(decoding: Data(hexString: fixture.responsePlaintextHex), as: UTF8.self)),
                AppAttestResumeFixture.nonce, try fixture.provider),
        ] {
            #expect(throws: (any Error).self) {
                try provider.appAttestResumeResponse(to: challenge, clientNonce: nonce, now: AppAttestResumeFixture.now)
            }
        }
    }

    @Test func rejectsMalformedTranscriptAndEveryMissingField() throws {
        let fixture = try AppAttestResumeFixture()
        var malformed: [String] = [
            fixture.requestJson.replacingOccurrences(of: "{", with: "{\"id\":\"duplicate\","),
            fixture.requestJson.replacingOccurrences(of: "{", with: "{\"\\u0069d\":\"duplicate\","),
            fixture.requestJson + "{}",
            fixture.requestJson.replacingOccurrences(of: "1791590400000", with: "1791590400000.0"),
            fixture.requestJson.replacingOccurrences(of: "1791590400000", with: "17915904e5"),
        ]
        let fields = try #require(JSONSerialization.jsonObject(with: Data(fixture.requestJson.utf8)) as? [String: Any])
        for key in fields.keys {
            var missing = fields
            missing.removeValue(forKey: key)
            malformed.append(String(decoding: try JSONSerialization.data(withJSONObject: missing), as: UTF8.self))
        }
        for overrides: [String: Any] in [
            ["unexpected": "field"], ["id": true], ["instance": NSNull()], ["record": []],
            ["domain": "darkbloom.app-attest.endpoint-resume.response.v1"],
            ["client_nonce": AppAttestResumeFixture.nonce.dropLast().description],
            ["record": "BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQV="],
            ["account": String(repeating: "A", count: 64)], ["identity": "abcd"],
            ["connection": ""], ["connection": String(repeating: "a", count: 65)],
            ["issued_at": -1], ["expires_at": 1_791_590_400_000],
            ["expires_at": 1_791_590_430_001], ["expires_at": "1791590430000"],
        ] { malformed.append(try fixture.request(overrides: overrides)) }
        for plaintext in malformed {
            let challenge = try fixture.seal(plaintext)
            #expect(throws: (any Error).self) {
                try fixture.provider.appAttestResumeResponse(to: challenge,
                    clientNonce: AppAttestResumeFixture.nonce, now: AppAttestResumeFixture.now)
            }
        }
    }

    @Test func enforcesTimeBounds() throws {
        let fixture = try AppAttestResumeFixture()
        for seconds: TimeInterval in [1_791_590_399.999, 1_791_590_430, .infinity, .nan] {
            #expect(throws: AppAttestResumeError.self) {
                try fixture.provider.appAttestResumeResponse(to: fixture.challenge,
                    clientNonce: AppAttestResumeFixture.nonce, now: Date(timeIntervalSince1970: seconds))
            }
        }
        for seconds: TimeInterval in [1_791_590_400, 1_791_590_429.999] {
            _ = try fixture.provider.appAttestResumeResponse(to: fixture.challenge,
                clientNonce: AppAttestResumeFixture.nonce, now: Date(timeIntervalSince1970: seconds))
        }
    }

    @Test func strictWireRejectsAmbiguityAndBoundsBothDirections() throws {
        let fixture = try AppAttestResumeFixture()
        let challenge = try ProviderProtocolCodec.encodeCoordinatorMessageString(.appAttestResume(fixture.challenge))
        let response = try ProviderProtocolCodec.encodeProviderMessageString(.appAttestResume(
            .init(id: AppAttestResumeFixture.id, ciphertext: fixture.responseCiphertext)))
        for (wire, isChallenge) in [(challenge, true), (response, false)] {
            func decode(_ input: String) throws {
                if isChallenge { _ = try ProviderProtocolCodec.decodeCoordinatorMessage(from: input) }
                else { _ = try ProviderProtocolCodec.decodeProviderMessage(from: input) }
            }
            try decode(wire)
            try decode(wire.replacingOccurrences(of: "\"type\":\"app_attest_resume\"",
                with: #""\u0074ype":"\u0061pp_attest_resume""#))
            try decode(String(repeating: " ", count: 4096 - wire.utf8.count) + wire)
            for bad in [
                "\u{FEFF}" + wire,
                wire + "{}", String(repeating: " ", count: 4097 - wire.utf8.count) + wire,
                wire.replacingOccurrences(of: "\"protocol\":1", with: "\"protocol\":1,\"protocol\":1"),
                wire.replacingOccurrences(of: "\"protocol\":1", with: "\"protocol\":1,\"extra\":0"),
                wire.replacingOccurrences(of: "\"protocol\":1", with: "\"protocol\":null"),
                wire.replacingOccurrences(of: "\"protocol\":1", with: "\"protocol\":true"),
                wire.replacingOccurrences(of: "\"protocol\":1", with: "\"protocol\":1.0"),
                wire.replacingOccurrences(of: "\"protocol\":1", with: "\"protocol\":1e0"),
                wire.replacingOccurrences(of: "\"protocol\":1", with: "\"protocol\":2"),
                wire.replacingOccurrences(of: "\"type\":", with: "\"type\":\"app_attest_resume\",\"type\":"),
                wire.replacingOccurrences(of: "\"type\":", with: #""type":"future_control","\u0074ype":"#),
                wire.replacingOccurrences(of: "\"type\":", with: "\"type\":true,\"type\":"),
                String(wire.dropLast()) + ",\"type\":\"future_control\"}",
                wire.replacingOccurrences(of: "\"ciphertext\":", with: "\"ciphertext\":\"duplicate\",\"ciphertext\":"),
                wire.replacingOccurrences(of: "\"ciphertext\":", with: "\"unknown\":true,\"ciphertext\":"),
                wire.replacingOccurrences(of: "\"payload\":", with: "\"extra\":0,\"payload\":"),
            ] { #expect(throws: AppAttestResumeError.self) { try decode(bad) } }
        }
        #expect(throws: (any Error).self) { try ProviderProtocolCodec.decodeCoordinatorMessage(from: response) }
        #expect(throws: (any Error).self) { try ProviderProtocolCodec.decodeProviderMessage(from: challenge) }
    }

    @Test func resumeSizeGatePrecedesEnvelopeDecoding() throws {
        let padding = String(repeating: "x", count: 8192)
        let payload = #"[{"type":"nested_decoy","text":"\"type\":\"app_attest_resume\"","values":[null,true,-1.5e2]},"\#(padding)"]"#
        let deepPayload = String(repeating: "[", count: 8192) + "0" + String(repeating: "]", count: 8192)
        for type in [
            #""type":"app_attest_resume""#,
            #""\u0074\u0079\u0070\u0065":"\u0061\u0070\u0070\u005f\u0061\u0074\u0074\u0065\u0073\u0074\u005f\u0072\u0065\u0073\u0075\u006d\u0065""#,
        ] {
            for wire in [
                "{\(type),\"payload\":\(payload)}",
                "\u{FEFF}{\(type),\"payload\":\(payload)}",
                "{\"payload\":\(payload),\(type)}",
                "{\"payload\":\(deepPayload),\(type)}",
                "{\(type),\"payload\":\(padding)}",
            ] {
                let data = Data(wire.utf8)
                // A payload decoding error must not precede the control-frame size gate.
                #expect(throws: AppAttestResumeError.self) { try ProviderProtocolCodec.decodeCoordinatorMessage(from: data) }
                #expect(throws: AppAttestResumeError.self) { try ProviderProtocolCodec.decodeProviderMessage(from: data) }
            }
        }
    }

    @Test(arguments: [String.Encoding.utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian])
    func alternateJSONEncodingsCannotBypassResumeGate(encoding: String.Encoding) throws {
        let fixture = try AppAttestResumeFixture()
        let challenge = try ProviderProtocolCodec.encodeCoordinatorMessageString(.appAttestResume(fixture.challenge))
        let response = try ProviderProtocolCodec.encodeProviderMessageString(.appAttestResume(
            .init(id: AppAttestResumeFixture.id, ciphertext: fixture.responseCiphertext)))
        for (wire, isChallenge) in [(challenge, true), (response, false)] {
            for bom in ["", "\u{FEFF}"] {
                for json in [wire, String(repeating: " ", count: 8192) + wire,
                    #"{"type":"app_attest_resume","payload":"\#(String(repeating: "x", count: 8192))"}"#] {
                    let data = try #require((bom + json).data(using: encoding))
                    // Reject before Foundation can transcode or decode even a malformed payload.
                    #expect(throws: ProtocolCodecError.nonUTF8Input) {
                        if isChallenge { _ = try ProviderProtocolCodec.decodeCoordinatorMessage(from: data) }
                        else { _ = try ProviderProtocolCodec.decodeProviderMessage(from: data) }
                    }
                }
            }
        }
    }

    @Test func nonResumeFramesKeepOrdinaryCodableSemantics() throws {
        let large = Data(repeating: 0, count: 8192).base64EncodedString()
        let request = CoordinatorMessage.inferenceRequest(.init(requestId: "large",
            encryptedBody: .init(ephemeralPublicKey: AppAttestResumeFixture.id, ciphertext: large)))
        let chunk = ProviderMessage.inferenceResponseChunk(.init(requestId: "large", data: large))
        let extra = #", "unknown":[{"type":"app_attest_resume"},null,true,-1.5e2,"\"type\":\"app_attest_resume\"" ]}"#
        let requestWire = try ProviderProtocolCodec.encodeCoordinatorMessageString(request)
        let chunkWire = try ProviderProtocolCodec.encodeProviderMessageString(chunk)
        for bom in ["", "\u{FEFF}"] {
            #expect(try ProviderProtocolCodec.decodeCoordinatorMessage(from: bom + String(requestWire.dropLast()) + extra) == request)
            #expect(try ProviderProtocolCodec.decodeProviderMessage(from: bom + String(chunkWire.dropLast()) + extra) == chunk)
        }
        for type in ["true", "null", "17", "[]", #""future_control""#] {
            let wire = "{\"payload\":{\"type\":\"app_attest_resume\"},\"type\":\(type)}"
            #expect(throws: DecodingError.self) { try ProviderProtocolCodec.decodeCoordinatorMessage(from: wire) }
            #expect(throws: DecodingError.self) { try ProviderProtocolCodec.decodeProviderMessage(from: wire) }
        }
    }

    @Test(arguments: [false, true]) func registrationNegotiatesAndPreservesLegacyOmission(rawAttestation: Bool) throws {
        let config = AppAttestResumeFixture.config(attestation: rawAttestation
            ? RawJSON(rawBytes: Data(#"{"signature" : "fixture", "nested":[{"type":"app_attest_resume"}]}"#.utf8)) : nil)
        for nonce in [nil, Optional(AppAttestResumeFixture.nonce)] {
            let data = try CoordinatorClientCodec.encodeRegistration(from: config, appAttestResumeNonce: nonce)
            let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(fields["app_attest_resume_nonce"] as? String == nonce)
            #expect(fields["app_attest_resume_protocol"] as? Int == (nonce == nil ? nil : 1))
            guard case .register(let decoded) = try ProviderProtocolCodec.decodeProviderMessage(from: data) else {
                Issue.record("expected register"); return
            }
            #expect(decoded.appAttestResumeNonce == nonce)
            #expect(decoded.appAttestResumeProtocol == (nonce == nil ? nil : 1))
            #expect(decoded.attestation?.rawBytes == config.attestation?.rawBytes)
        }
    }
}
