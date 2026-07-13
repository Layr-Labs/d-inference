import Foundation
import Testing

@testable import ProviderCore

@Suite("Protocol v2 Rust contract parity")
struct V2ProtocolTests {
    @Test("UUID text and protocol capability negotiation match Rust")
    func identityAndCapabilities() throws {
        let id = try #require(ProtocolV2UUID("00112233-4455-6677-8899-aabbccddeeff"))
        #expect(id.description == "00112233-4455-6677-8899-aabbccddeeff")
        #expect(
            ProtocolV2UUID("00112233445566778899AABBCCDDEEFF") == id
        )
        #expect(ProtocolV2UUID("001122334455-66778899aabbccddeeff") == nil)
        #expect(
            String(data: try JSONEncoder().encode(id), encoding: .utf8)
                == #""00112233-4455-6677-8899-aabbccddeeff""#)

        let left = ProtocolCapabilities(
            protocolMajor: 2,
            protocolMinor: 5,
            minimumCompatibleMinor: 2,
            preparedLeases: true
        )
        let right = ProtocolCapabilities(
            protocolMajor: 2,
            protocolMinor: 3,
            minimumCompatibleMinor: 1,
            preparedLeases: true,
            startAck: true
        )
        let negotiated = try #require(left.negotiate(with: right))
        #expect(negotiated == right.negotiate(with: left))
        #expect(negotiated.minimumCompatibleMinor == 2)
        #expect(negotiated.protocolMinor == 3)
        #expect(negotiated.preparedLeases)
        #expect(!negotiated.startAck)

        let disjoint = ProtocolCapabilities(
            protocolMajor: 2,
            protocolMinor: 8,
            minimumCompatibleMinor: 6
        )
        #expect(right.negotiate(with: disjoint) == nil)
        #expect(ProtocolCapabilities.current.supportsV2)
    }

    @Test("all committed control discriminators flatten AttemptIdentity")
    func controlMessages() throws {
        let id = rustIdentity()
        let digest = ProtocolV2Digest(bytes: Data(repeating: 9, count: 32))!
        let encryptedBody = EncryptedPayload(
            ephemeralPublicKey: Data(repeating: 0xAB, count: 32).base64EncodedString(),
            ciphertext: Data(repeating: 0xCD, count: 40).base64EncodedString()
        )
        let coordinator: [(V2CoordinatorControlMessage, String)] = [
            (
                .prepare(
                    V2Prepare(
                        identity: id,
                        model: "model-a",
                        requestDigest: digest,
                        encryptedBody: encryptedBody
                    )),
                "prepare"
            ),
            (.start(V2Start(identity: id)), "start"),
            (.queryAttempt(V2QueryAttempt(identity: id)), "query_attempt"),
            (.abort(V2Abort(identity: id)), "abort"),
            (.cancel(V2Cancel(identity: id, reason: "consumer_gone")), "cancel"),
            (
                .terminalAck(
                    V2TerminalAck(
                        identity: id,
                        terminalDigest: digest,
                        disposition: .settled
                    )),
                "terminal_ack"
            ),
        ]
        for (message, type) in coordinator {
            let encoded = try sortedEncoder().encode(message)
            let object = try jsonObject(encoded)
            #expect(object["type"] as? String == type)
            #expect(object["provider_id"] as? String == id.providerID.description)
            #expect(
                object["provider_process_generation"] as? String
                    == id.providerProcessGeneration.description)
            #expect(object["session_epoch"] as? UInt64 == 7)
            #expect(
                try JSONDecoder().decode(
                    V2CoordinatorControlMessage.self, from: encoded) == message)
        }
        let query = CoordinatorMessage.queryAttempt(V2QueryAttempt(identity: id))
        let queryWire = try ProviderProtocolCodec.encodeCoordinatorMessage(query)
        #expect(
            CoordinatorClientCodec.v2ControlMessage(from: query)
                == .queryAttempt(V2QueryAttempt(identity: id))
        )
        #expect(
            try ProviderProtocolCodec.decodeCoordinatorMessage(
                from: queryWire,
                negotiatedV2Session: true
            ) == query
        )

        let futurePrepared = Data(
            #"""
            {
              "type":"prepared",
              "provider_id":"11111111-1111-1111-1111-111111111111",
              "provider_process_generation":"22222222-2222-2222-2222-222222222222",
              "session_epoch":7,
              "request_id":"33333333-3333-3333-3333-333333333333",
              "attempt_id":"44444444-4444-4444-4444-444444444444",
              "reservation_id":"55555555-5555-5555-5555-555555555555",
              "lease_id":"66666666-6666-6666-6666-666666666666",
              "model":"model-a",
              "request_digest":"CQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQk=",
              "lease_ttl_ms":15000,
              "prompt_tokens":42,
              "max_output_tokens":128,
              "engine_queue_depth":0,
              "reserved_kv_bytes":4096,
              "reserved_media_bytes":0,
              "prefill_can_begin":true,
              "future":{"nested":true}
            }
            """#.utf8)
        let decoded = try JSONDecoder().decode(
            V2ProviderControlMessage.self, from: futurePrepared)
        guard case .prepared(let prepared) = decoded else {
            Issue.record("expected prepared")
            return
        }
        #expect(prepared.identity == id)
        #expect(prepared.leaseTTLMilliseconds == 15_000)

        let alias = Data(
            String(data: futurePrepared, encoding: .utf8)!
                .replacingOccurrences(of: #""type":"prepared""#, with: #""type":"started""#)
                .replacingOccurrences(
                    of:
                        #","model":"model-a","request_digest":"CQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQk=","lease_ttl_ms":15000,"prompt_tokens":42,"max_output_tokens":128,"engine_queue_depth":0,"reserved_kv_bytes":4096,"reserved_media_bytes":0,"prefill_can_begin":true,"future":{"nested":true}"#,
                    with: ""
                ).utf8)
        guard
            case .startAck(let started) = try JSONDecoder().decode(
                V2ProviderControlMessage.self, from: alias)
        else {
            Issue.record("expected started alias")
            return
        }
        #expect(started.identity == id)

        let structured = V2ProviderControlMessage.structuredError(
            V2StructuredError(
                identity: id,
                errorClass: .modelNotReady,
                message: "loading"
            )
        )
        let structuredObject = try jsonObject(sortedEncoder().encode(structured))
        #expect(structuredObject["type"] as? String == "structured_error")
        #expect(structuredObject["class"] as? String == "model_not_ready")
        #expect(structuredObject["error_class"] == nil)
        #expect(
            try JSONDecoder().decode(
                V2ProviderControlMessage.self,
                from: sortedEncoder().encode(structured)
            ) == structured)

        let terminal = V2ProviderTerminal(
            identity: id,
            outcome: .cancelled,
            promptTokens: 42,
            completionTokens: 0,
            responseHash: .zero,
            finalGeneratedTokens: 0,
            rollingDigest: .zero,
            model: "model-a",
            signature: V2TerminalSignature(bytes: Data([1]))
        )
        let providerAttemptMessages: [V2ProviderControlMessage] = [
            .prepared(
                V2Prepared(
                    identity: id,
                    model: "model-a",
                    requestDigest: digest,
                    leaseTTLMilliseconds: 15_000,
                    promptTokens: 42,
                    maxOutputTokens: 128,
                    engineQueueDepth: 0,
                    reservedKVBytes: 4_096,
                    reservedMediaBytes: 0,
                    prefillCanBegin: true
                )),
            .startAck(V2StartAck(identity: id)),
            .attemptStatus(
                try V2AttemptStatus(
                    identity: id,
                    state: .terminal,
                    terminalDigest: digest
                )),
            .abortAck(V2AbortAck(identity: id)),
            .cancelAck(V2CancelAck(identity: id)),
            .terminal(terminal),
            structured,
        ]
        for message in providerAttemptMessages {
            let encoded = try sortedEncoder().encode(message)
            let object = try jsonObject(encoded)
            #expect(object["provider_id"] as? String == id.providerID.description)
            #expect(
                object["provider_process_generation"] as? String
                    == id.providerProcessGeneration.description)
            #expect(
                try JSONDecoder().decode(
                    V2ProviderControlMessage.self,
                    from: encoded
                ) == message)
        }
        let invalidAttemptStatus = Data(
            String(data: try sortedEncoder().encode(
                V2ProviderControlMessage.attemptStatus(
                    try V2AttemptStatus(
                        identity: id,
                        state: .terminal,
                        terminalDigest: digest
                    ))
            ), encoding: .utf8)!
                .replacingOccurrences(of: #","terminal_digest":"CQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQk=""#, with: "")
                .utf8
        )
        #expect(throws: V2AttemptStatusError.invalidTerminalDigestShape) {
            _ = try JSONDecoder().decode(
                V2ProviderControlMessage.self,
                from: invalidAttemptStatus
            )
        }
        let status = try V2AttemptStatus(
            identity: id,
            state: .terminal,
            terminalDigest: digest
        )
        let statusWire = try ProviderProtocolCodec.encodeProviderMessage(
            .attemptStatus(status)
        )
        #expect(
            CoordinatorClientCodec.v2ControlMessage(from: .attemptStatus(status))
                == .attemptStatus(status)
        )
        #expect(
            try ProviderProtocolCodec.decodeProviderMessage(from: statusWire)
                == .attemptStatus(status)
        )

        let replayAck = V2ProviderControlMessage.replayFenceAck(
            V2ReplayFenceAck(
                proofID: repeatedID(0x99),
                providerID: id.providerID,
                providerProcessGeneration: repeatedID(0x77)
            ))
        let replayAckData = try sortedEncoder().encode(replayAck)
        let replayAckObject = try jsonObject(replayAckData)
        #expect(replayAckObject["type"] as? String == "replay_fence_ack")
        #expect(
            replayAckObject["proof_id"] as? String
                == repeatedID(0x99).description)
        #expect(
            replayAckObject["provider_id"] as? String
                == id.providerID.description)
        #expect(
            replayAckObject["provider_process_generation"] as? String
                == repeatedID(0x77).description)
        #expect(
            try JSONDecoder().decode(
                V2ProviderControlMessage.self,
                from: replayAckData
            ) == replayAck)

        let sessionIdentity = id.providerSessionIdentity
        for message in [
            V2ProviderControlMessage.modelReady(
                V2ModelReady(
                    identity: sessionIdentity,
                    model: "model-a",
                    stateRevision: 4,
                    weightHash: "hash"
                )),
            .modelGone(
                V2ModelGone(
                    identity: sessionIdentity,
                    model: "model-a",
                    stateRevision: 5,
                    reason: "evicted"
                )),
        ] {
            let encoded = try sortedEncoder().encode(message)
            let object = try jsonObject(encoded)
            #expect(object["provider_id"] as? String == sessionIdentity.providerID.description)
            #expect(
                object["process_generation"] as? String
                    == sessionIdentity.processGeneration.description)
            #expect(object["provider_process_generation"] == nil)
            #expect(
                try JSONDecoder().decode(
                    V2ProviderControlMessage.self,
                    from: encoded
                ) == message)
        }
    }

    @Test("prepare requires encrypted object and binds key plus ciphertext")
    func encryptedPrepareOnly() throws {
        let key = Data(repeating: 0x11, count: 32)
        let ciphertext = Data(repeating: 0x22, count: 40)
        let payload = EncryptedPayload(
            ephemeralPublicKey: key.base64EncodedString(),
            ciphertext: ciphertext.base64EncodedString()
        )
        let digest = try V2Prepare.digest(of: payload)
        let changed = EncryptedPayload(
            ephemeralPublicKey: Data(repeating: 0x33, count: 32)
                .base64EncodedString(),
            ciphertext: ciphertext.base64EncodedString()
        )
        #expect(try V2Prepare.digest(of: changed) != digest)

        let plaintextOnly = Data(
            #"""
            {
              "type":"prepare",
              "provider_id":"11111111-1111-1111-1111-111111111111",
              "provider_process_generation":"22222222-2222-2222-2222-222222222222",
              "session_epoch":7,
              "request_id":"33333333-3333-3333-3333-333333333333",
              "attempt_id":"44444444-4444-4444-4444-444444444444",
              "reservation_id":"55555555-5555-5555-5555-555555555555",
              "lease_id":"66666666-6666-6666-6666-666666666666",
              "model":"model-a",
              "request_digest":"CQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQk=",
              "body":{"model":"model-a","messages":[]}
            }
            """#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(
                V2CoordinatorControlMessage.self, from: plaintextOnly)
        }
    }

    @Test("terminal canonical bytes pin the committed Rust vector")
    func terminalCanonicalVector() throws {
        var terminal = V2ProviderTerminal(
            identity: rustIdentity(),
            outcome: .completed,
            promptTokens: 10,
            completionTokens: 5,
            responseHash: ProtocolV2Digest(bytes: Data(repeating: 0x77, count: 32))!,
            finalGeneratedTokens: 5,
            rollingDigest: ProtocolV2Digest(bytes: Data(repeating: 0x88, count: 32))!,
            model: "model-a",
            signature: V2TerminalSignature(bytes: Data([0x30, 0x01, 0x02]))
        )
        let expected =
            #"{"attempt_id":"44444444-4444-4444-4444-444444444444","completion_tokens":5,"final_generated_tokens":5,"lease_id":"66666666-6666-6666-6666-666666666666","model":"model-a","outcome":"completed","prompt_tokens":10,"provider_id":"11111111-1111-1111-1111-111111111111","provider_process_generation":"22222222-2222-2222-2222-222222222222","request_id":"33333333-3333-3333-3333-333333333333","reservation_id":"55555555-5555-5555-5555-555555555555","response_hash":"d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3c=","rolling_digest":"iIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIg=","session_epoch":7}"#
        #expect(String(data: try terminal.canonicalBytes(), encoding: .utf8) == expected)

        terminal.terminalDigest = try terminal.computedDigest()
        try terminal.validate(
            expectedIdentity: rustIdentity(),
            verifySignature: { provider, generation, digest, signature in
                provider == repeatedID(0x11)
                    && generation == repeatedID(0x22)
                    && digest == terminal.terminalDigest
                    && signature == Data([0x30, 0x01, 0x02])
            }
        )

        var tampered = terminal
        tampered.completionTokens += 1
        #expect(throws: V2TerminalValidationError.digestMismatch) {
            try tampered.validate(
                expectedIdentity: rustIdentity(),
                verifySignature: { _, _, _, _ in true }
            )
        }

        let digestJSON = try JSONEncoder().encode(terminal.responseHash)
        let unpadded = Data(
            String(decoding: digestJSON, as: UTF8.self)
                .replacingOccurrences(of: "=", with: "")
                .utf8
        )
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(ProtocolV2Digest.self, from: unpadded)
        }

        var legacyAliasObject = try jsonObject(sortedEncoder().encode(terminal))
        legacyAliasObject["rolling_hash_checkpoint"] =
            legacyAliasObject.removeValue(forKey: "rolling_digest")
        legacyAliasObject["signature"] =
            legacyAliasObject.removeValue(forKey: "se_signature")
        let legacyAliasData = try JSONSerialization.data(withJSONObject: legacyAliasObject)
        #expect(
            try JSONDecoder().decode(
                V2ProviderTerminal.self,
                from: legacyAliasData
            ) == terminal)

        var duplicateAliasObject = legacyAliasObject
        duplicateAliasObject["rolling_digest"] =
            legacyAliasObject["rolling_hash_checkpoint"]
        duplicateAliasObject["se_signature"] = legacyAliasObject["signature"]
        let duplicateAliasData = try JSONSerialization.data(
            withJSONObject: duplicateAliasObject)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(
                V2ProviderTerminal.self,
                from: duplicateAliasData
            )
        }
    }

    @Test("registration keeps generation top-level and v1 opt-out byte shape")
    func registrationFields() throws {
        let generation = repeatedID(0xaa)
        let register = ProviderMessage.Register(
            hardware: sampleHardware(),
            models: [],
            backend: "mlx_swift_lm",
            protocolCapabilities: .current,
            providerProcessGeneration: generation
        )
        let encoded = try ProviderProtocolCodec.encodeProviderMessage(.register(register))
        let object = try jsonObject(encoded)
        #expect(object["provider_process_generation"] as? String == generation.description)
        let capabilities = try #require(object["protocol_capabilities"] as? [String: Any])
        #expect(capabilities["process_generation"] == nil)
        #expect(
            Set(capabilities.keys) == [
                "protocol_major",
                "protocol_minor",
                "prepared_leases",
                "start_authorization",
                "structured_errors",
                "start_ack",
                "abort_ack",
                "cancel_ack",
                "durable_terminals",
                "model_lifecycle_events",
                "binary_payload_frames",
                "coordinator_replay_fences",
                "attempt_reconciliation",
            ])
        #expect(capabilities["protocol_major"] as? UInt16 == protocolV2Major)
        #expect(capabilities["protocol_minor"] as? UInt16 == 0)
        for key in [
            "prepared_leases",
            "start_authorization",
            "structured_errors",
            "start_ack",
            "abort_ack",
            "cancel_ack",
            "durable_terminals",
            "model_lifecycle_events",
            "binary_payload_frames",
            "coordinator_replay_fences",
            "attempt_reconciliation",
        ] {
            #expect(capabilities[key] as? Bool == true)
        }

        let v1 = ProviderMessage.Register(
            hardware: sampleHardware(),
            models: [],
            backend: "mlx_swift_lm"
        )
        let v1Object = try jsonObject(
            ProviderProtocolCodec.encodeProviderMessage(.register(v1)))
        #expect(v1Object["protocol_capabilities"] == nil)
        #expect(v1Object["provider_process_generation"] == nil)

        // Production registrations use the raw-attestation encoder, which must
        // preserve the signed blob while carrying the same top-level v2 fields.
        let attested = ProviderMessage.Register(
            hardware: sampleHardware(),
            models: [],
            backend: "mlx_swift_lm",
            attestation: RawJSON(rawBytes: Data(#"{"signed":"bytes"}"#.utf8)),
            protocolCapabilities: .current,
            providerProcessGeneration: generation
        )
        let attestedData = try ProviderProtocolCodec.encodeProviderMessage(.register(attested))
        let attestedObject = try jsonObject(attestedData)
        #expect(attestedObject["attestation"] as? [String: String] == ["signed": "bytes"])
        #expect(
            attestedObject["provider_process_generation"] as? String
                == generation.description)
        #expect(
            (attestedObject["protocol_capabilities"] as? [String: Any])?[
                "durable_terminals"
            ] as? Bool == true)

        let missingGeneration = ProviderMessage.Register(
            hardware: sampleHardware(),
            models: [],
            backend: "mlx_swift_lm",
            protocolCapabilities: .current
        )
        let malformed = try JSONEncoder().encode(ProviderMessage.register(missingGeneration))
        #expect(throws: ProtocolCodecError.missingProviderProcessGeneration) {
            _ = try ProviderProtocolCodec.decodeProviderMessage(from: malformed)
        }
    }
}

private func rustIdentity() -> AttemptIdentity {
    AttemptIdentity(
        providerID: repeatedID(0x11),
        providerProcessGeneration: repeatedID(0x22),
        sessionEpoch: 7,
        requestID: repeatedID(0x33),
        attemptID: repeatedID(0x44),
        reservationID: repeatedID(0x55),
        leaseID: repeatedID(0x66)
    )
}

private func repeatedID(_ byte: UInt8) -> ProtocolV2UUID {
    ProtocolV2UUID(bytes: Data(repeating: byte, count: 16))!
}

private func sampleHardware() -> HardwareInfo {
    HardwareInfo(
        machineModel: "Mac16,5",
        chipName: "Apple M4 Max",
        chipFamily: .m4,
        chipTier: .max,
        memoryGb: 128,
        memoryAvailableGb: 124,
        cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
        gpuCores: 40,
        memoryBandwidthGbs: 546
    )
}

private func sortedEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
