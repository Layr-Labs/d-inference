import Foundation
import Testing
@testable import ProviderCore


@Test func prefixCacheTelemetryEnumCasingIsPinned() {
    #expect(Set(PrefixCacheStatusState.allCases.map(\.rawValue)) == [
        "ready", "pending", "disabled", "error",
    ])
    #expect(Set(PrefixCacheStatusReason.allCases.map(\.rawValue)) == [
        "ready", "config_disabled",
        "weight_hash_unavailable", "runtime_identity_unavailable",
        "unsupported_layout", "unsupported_backend",
        "paged_hybrid_unsupported", "scan_pending", "scan_failed",
        "disk_unavailable", "cache_init_failed",
    ])
    #expect(Set(PrefixCacheStatusBackend.allCases.map(\.rawValue)) == [
        "contiguous", "paged", "unknown",
    ])
    #expect(Set(PrefixCacheReplayStrategy.allCases.map(\.rawValue)) == [
        "direct", "frozen_full", "tail_replay", "none", "unknown",
    ])
    #expect(Set(PrefixCacheDonationOutcome.allCases.map(\.rawValue)) == [
        "donated", "below_effective_token_floor", "no_complete_block",
        "lossy_snapshot", "incomplete_layer_state", "stage_size_exceeded",
        "write_rate_limited", "write_queue_full", "already_durable",
        "already_queued", "cache_closed", "disk_unavailable", "write_failed",
    ])
}

@Test func prefixCacheV2MessagesRemainDistinctAndBoundReadyAnchors() throws {
    let prompt = PrefixCacheAnchor(
        chainHash: String(repeating: "c", count: 64), tokenCount: 256)
    let continuation = PrefixCacheAnchor(
        chainHash: String(repeating: "d", count: 64), tokenCount: 512)
    let excess = PrefixCacheAnchor(
        chainHash: String(repeating: "e", count: 64), tokenCount: 768)
    let lookup = ProviderMessage.prefixCacheLookupV2(
        ProviderMessage.PrefixCacheLookupV2(
            requestId: "request",
            cacheReceiptNonce: "nonce",
            modelId: "model",
            modelAggregateHash: String(repeating: "a", count: 64),
            promptContractId: String(repeating: "b", count: 64),
            cacheEpoch: "11111111-1111-1111-1111-111111111111",
            cacheSeq: 1,
            promptAnchor: prompt,
            matchedAnchor: nil,
            outcome: .missAbsent,
            tier: .ssd,
            requiredRecomputeTokens: 0,
            expectedPrefillTokensSaved: 0,
            stageMs: 1))
    let lookupData = try ProviderProtocolCodec.encodeProviderMessage(lookup)
    #expect(try jsonObject(lookupData)["type"] as? String == "prefix_cache_lookup_v2")
    guard case .prefixCacheLookupV2(let decodedLookup) =
        try ProviderProtocolCodec.decodeProviderMessage(from: lookupData)
    else {
        throw TestFailure.unexpectedMessage
    }
    #expect(decodedLookup.promptAnchor == prompt)

    let ready = ProviderMessage.prefixCacheReadyV2(
        ProviderMessage.PrefixCacheReadyV2(
            requestId: "request",
            cacheReceiptNonce: "nonce",
            modelId: "model",
            modelAggregateHash: String(repeating: "a", count: 64),
            promptContractId: String(repeating: "b", count: 64),
            cacheEpoch: "11111111-1111-1111-1111-111111111111",
            cacheSeq: 2,
            tier: .ssd,
            readyAnchors: [prompt, continuation, excess],
            requiredRecomputeTokens: 256,
            expectedPrefillTokensSaved: 256,
            stageMs: 2))
    let readyData = try ProviderProtocolCodec.encodeProviderMessage(ready)
    guard case .prefixCacheReadyV2(let decodedReady) =
        try ProviderProtocolCodec.decodeProviderMessage(from: readyData)
    else {
        throw TestFailure.unexpectedMessage
    }
    #expect(decodedReady.readyAnchors == [prompt, continuation])
}

@Test func registerEncodingUsesSnakeCaseAndPreservesRawAttestation() throws {
    let rawAttestation = #"{"signature":"sig","attestation":{"z":1,"a":[true,false],"path":"a/b"}}"#
    let rawData = Data(rawAttestation.utf8)
    let message = ProviderMessage.register(ProviderMessage.Register(
        hardware: sampleHardware(),
        models: [sampleModel()],
        backend: "mlx_swift_lm",
        version: "0.4.0-swift",
        publicKey: "cHVibGlj",
        encryptedResponseChunks: true,
        attestation: RawJSON(rawBytes: rawData),
        prefillTps: 512.5,
        decodeTps: 123.25,
        templateHashes: ["chatml": "templatehash"],
        privacyCapabilities: samplePrivacyCapabilities()
    ))

    let data = try ProviderProtocolCodec.encodeProviderMessage(message)
    let json = String(data: data, encoding: .utf8) ?? ""
    let object = try jsonObject(data)

    #expect(object["type"] as? String == "register")
    #expect(object["encrypted_response_chunks"] as? Bool == true)
    #expect(object["public_key"] as? String == "cHVibGlj")
    #expect(object["prefill_tps"] as? Double == 512.5)
    #expect(object["decode_tps"] as? Double == 123.25)
    #expect(object["wallet_address"] == nil)
    #expect(object["auth_token"] == nil)
    #expect(json.contains(#""attestation":\#(rawAttestation)"#))

    let decoded = try ProviderProtocolCodec.decodeProviderMessage(from: data)
    guard case .register(let register) = decoded else {
        throw TestFailure.unexpectedMessage
    }
    #expect(register.attestation?.rawBytes == rawData)
}

@Test func registerEncodesPrivateOnlyOnlyWhenTrue() throws {
    // Default (false): the flag is omitted, mirroring the Go `omitempty` tag.
    let off = ProviderMessage.register(ProviderMessage.Register(
        hardware: sampleHardware(),
        models: [sampleModel()],
        backend: "mlx_swift_lm"
    ))
    let offObject = try jsonObject(try ProviderProtocolCodec.encodeProviderMessage(off))
    #expect(offObject["private_only"] == nil)

    // Explicit true: encoded as snake_case and round-trips back to true.
    let on = ProviderMessage.register(ProviderMessage.Register(
        hardware: sampleHardware(),
        models: [sampleModel()],
        backend: "mlx_swift_lm",
        privateOnly: true
    ))
    let onData = try ProviderProtocolCodec.encodeProviderMessage(on)
    let onObject = try jsonObject(onData)
    #expect(onObject["private_only"] as? Bool == true)

    let decoded = try ProviderProtocolCodec.decodeProviderMessage(from: onData)
    guard case .register(let register) = decoded else {
        throw TestFailure.unexpectedMessage
    }
    #expect(register.privateOnly == true)
}

@Test func registerEncodesAPNsFieldsOnlyWhenPresent() throws {
    // Omitted when nil (mirrors Go `omitempty`).
    let off = ProviderMessage.register(ProviderMessage.Register(
        hardware: sampleHardware(),
        models: [sampleModel()],
        backend: "mlx_swift_lm"
    ))
    let offObject = try jsonObject(try ProviderProtocolCodec.encodeProviderMessage(off))
    #expect(offObject["apns_device_token"] == nil)
    #expect(offObject["apns_environment"] == nil)

    // Present: snake_case keys, round-trips back to the same values.
    let on = ProviderMessage.register(ProviderMessage.Register(
        hardware: sampleHardware(),
        models: [sampleModel()],
        backend: "mlx_swift_lm",
        apnsDeviceToken: "cb1ceb489ec9",
        apnsEnvironment: "production"
    ))
    let onData = try ProviderProtocolCodec.encodeProviderMessage(on)
    let onObject = try jsonObject(onData)
    #expect(onObject["apns_device_token"] as? String == "cb1ceb489ec9")
    #expect(onObject["apns_environment"] as? String == "production")

    let decoded = try ProviderProtocolCodec.decodeProviderMessage(from: onData)
    guard case .register(let register) = decoded else {
        throw TestFailure.unexpectedMessage
    }
    #expect(register.apnsDeviceToken == "cb1ceb489ec9")
    #expect(register.apnsEnvironment == "production")
}

@Test func registerWithAttestationPreservesAPNsAndPrivateOnly() throws {
    // The raw-attestation encoding path (ProtocolCodec.encodeRegisterPreservingRawAttestation)
    // BYPASSES the Codable encoder, so the Codable-path tests above don't cover it.
    // This is the ATTESTED registration (production-common): every Register field
    // must survive this path too, or it silently drops on the wire.
    let raw = #"{"signature":"sig","blob":{"a":1,"b":[true,false]}}"#
    let capability = PrefixCacheV2Capability(
        modelId: "model",
        modelAggregateHash: String(repeating: "a", count: 64),
        promptContractId: String(repeating: "b", count: 64),
        blockHashVersion: "dbk3",
        blockSize: 256,
        cacheEpoch: "11111111-1111-1111-1111-111111111111",
        enabled: true,
        ready: true)
    let cacheStatus = PrefixCacheModelStatus(
        modelId: "model",
        backend: .contiguous,
        replayStrategy: .direct,
        state: .ready,
        reason: .ready)
    let donationOutcome = PrefixCacheDonationOutcomeCount(
        outcome: .donated, count: 7)
    let message = ProviderMessage.register(ProviderMessage.Register(
        hardware: sampleHardware(),
        models: [sampleModel()],
        backend: "mlx_swift_lm",
        attestation: RawJSON(rawBytes: Data(raw.utf8)),
        privateOnly: true,
        apnsDeviceToken: "cb1ceb489ec9",
        apnsEnvironment: "production",
        prefixCacheProtocol: 2,
        prefixCacheV2Models: [capability],
        prefixCacheStatuses: [cacheStatus],
        prefixCacheDonationOutcomes: [donationOutcome],
        toolConstraintProtocol: 1,
        toolConstraintModels: ["model"]
    ))
    let data = try ProviderProtocolCodec.encodeProviderMessage(message)
    let object = try jsonObject(data)
    #expect(object["apns_device_token"] as? String == "cb1ceb489ec9")
    #expect(object["apns_environment"] as? String == "production")
    #expect(object["private_only"] as? Bool == true)
    #expect(object["prefix_cache_protocol"] as? Int == 2)
    #expect((object["prefix_cache_v2_models"] as? [[String: Any]])?.count == 1)
    #expect((object["prefix_cache_statuses"] as? [[String: Any]])?.count == 1)
    #expect((object["prefix_cache_donation_outcomes"] as? [[String: Any]])?.count == 1)
    #expect(object["tool_constraint_protocol"] as? Int == 1)
    #expect(object["tool_constraint_models"] as? [String] == ["model"])
    // Raw attestation bytes preserved verbatim (the reason this path exists).
    let json = String(data: data, encoding: .utf8) ?? ""
    #expect(json.contains(#""attestation":\#(raw)"#))

    let decoded = try ProviderProtocolCodec.decodeProviderMessage(from: data)
    guard case .register(let r) = decoded else { throw TestFailure.unexpectedMessage }
    #expect(r.apnsDeviceToken == "cb1ceb489ec9")
    #expect(r.apnsEnvironment == "production")
    #expect(r.privateOnly == true)
    #expect(r.prefixCacheV2Models == [capability])
    #expect(r.prefixCacheStatuses == [cacheStatus])
    #expect(r.prefixCacheDonationOutcomes == [donationOutcome])
    #expect(r.toolConstraintProtocol == 1)
    #expect(r.toolConstraintModels == ["model"])
}

@Test func codeAttestationResponseEncodesSnakeCaseAndRoundTrips() throws {
    // The WebSocket return leg of the APNs push round-trip. Must match the Go
    // CodeAttestationResponseMessage wire shape (type=code_attestation_response).
    let message = ProviderMessage.codeAttestationResponse(
        ProviderMessage.CodeAttestationResponse(nonce: "bm9uY2U=", signature: "c2ln")
    )
    let data = try ProviderProtocolCodec.encodeProviderMessage(message)
    let object = try jsonObject(data)
    #expect(object["type"] as? String == "code_attestation_response")
    #expect(object["nonce"] as? String == "bm9uY2U=")
    #expect(object["signature"] as? String == "c2ln")

    let decoded = try ProviderProtocolCodec.decodeProviderMessage(from: data)
    guard case .codeAttestationResponse(let resp) = decoded else {
        throw TestFailure.unexpectedMessage
    }
    #expect(resp.nonce == "bm9uY2U=")
    #expect(resp.signature == "c2ln")
}

@Test func providerMessagesRoundTripThroughCodableEnvelope() throws {
    let messages: [ProviderMessage] = [
        .register(ProviderMessage.Register(
            hardware: sampleHardware(),
            models: [sampleModel()],
            backend: "mlx_swift_lm",
            encryptedResponseChunks: true
        )),
        .heartbeat(ProviderMessage.Heartbeat(
            status: .serving,
            activeModel: "mlx-community/Qwen2.5-7B-4bit",
            warmModels: ["mlx-community/Qwen2.5-7B-4bit"],
            stats: ProviderStats(requestsServed: 4, tokensGenerated: 4096),
            systemMetrics: SystemMetrics(memoryPressure: 0.2, cpuUsage: 0.3, thermalState: .nominal),
            backendCapacity: BackendCapacity(
                slots: [BackendSlotCapacity(
                    model: "mlx-community/Qwen2.5-7B-4bit",
                    state: "running",
                    numRunning: 1,
                    numWaiting: 0,
                    activeTokens: 512,
                    maxTokensPotential: 2048,
                    maxConcurrency: 4
                )],
                gpuMemoryActiveGb: 8.5,
                gpuMemoryPeakGb: 9.0,
                gpuMemoryCacheGb: 1.25,
                totalMemoryGb: 64.0
            )
        )),
        .inferenceAccepted(ProviderMessage.InferenceAccepted(requestId: "req-accepted")),
        .inferenceResponseChunk(ProviderMessage.InferenceResponseChunk(
            requestId: "req-chunk",
            data: "data: {\"choices\":[]}\n\n"
        )),
        .inferenceResponseChunk(ProviderMessage.InferenceResponseChunk(
            requestId: "req-encrypted",
            encryptedData: EncryptedPayload(ephemeralPublicKey: "ZXBoZW1lcmFs", ciphertext: "Y2lwaGVy")
        )),
        .inferenceComplete(ProviderMessage.InferenceComplete(
            requestId: "req-complete",
            usage: UsageInfo(promptTokens: 12, completionTokens: 34),
            stopSequence: "<END>",
            seSignature: "c2ln",
            responseHash: "aGFzaA=="
        )),
        .inferenceError(ProviderMessage.InferenceError(
            requestId: "req-error",
            failure: InferenceFailure(code: .modelUnavailable, statusCode: 503)
        )),
        .attestationResponse(ProviderMessage.AttestationResponse(
            nonce: "bm9uY2U=",
            signature: "c2ln",
            statusSignature: "c3RhdHVz",
            publicKey: "cGs=",
            rdmaDisabled: true,
            sipEnabled: true,
            secureBootEnabled: true,
            binaryHash: "binaryhash",
            activeModelHash: "modelhash",
            runtimeHash: "runtimehash",
            templateHashes: ["chatml": "templatehash"],
            modelHashes: ["model": "weighthash"]
        )),
    ]

    for message in messages {
        let encoded = try ProviderProtocolCodec.encodeProviderMessage(message)
        let decoded = try ProviderProtocolCodec.decodeProviderMessage(from: encoded)
        #expect(decoded == message)
    }
}

@Test func inferenceErrorEncodesErrorReasonOnlyWhenPresent() throws {
    // DAR-341: the normalized `error_reason` rides the inference-error message.
    // Present → snake_case key on the wire + round-trips back to the value.
    let withReason = ProviderMessage.inferenceError(ProviderMessage.InferenceError(
        requestId: "req-error",
        failure: InferenceFailure(
            code: .templateRender,
            statusCode: 422,
            errorReason: .jinjaChannelTags)
    ))
    let withData = try ProviderProtocolCodec.encodeProviderMessage(withReason)
    let withObject = try jsonObject(withData)
    #expect(withObject["error_reason"] as? String == "jinja_channel_tags")

    let decodedWith = try ProviderProtocolCodec.decodeProviderMessage(from: withData)
    #expect(decodedWith == withReason)
    guard case .inferenceError(let e) = decodedWith else { throw TestFailure.unexpectedMessage }
    #expect(e.errorReason == .jinjaChannelTags)

    // Absent (nil) → the key is OMITTED on the wire (mirrors Go `omitempty`) and
    // round-trips back to nil.
    let withoutReason = ProviderMessage.inferenceError(ProviderMessage.InferenceError(
        requestId: "req-error",
        failure: InferenceFailure(code: .modelUnavailable, statusCode: 503)
    ))
    let withoutData = try ProviderProtocolCodec.encodeProviderMessage(withoutReason)
    let withoutObject = try jsonObject(withoutData)
    #expect(withoutObject["error_reason"] == nil)

    let decodedWithout = try ProviderProtocolCodec.decodeProviderMessage(from: withoutData)
    #expect(decodedWithout == withoutReason)
    guard case .inferenceError(let e2) = decodedWithout else { throw TestFailure.unexpectedMessage }
    #expect(e2.errorReason == nil)
}

@Test func inferenceErrorUnknownTerminalCauseDecodesAsLegacy() throws {
    let unknownJSON = #"{"type":"inference_error","request_id":"r","error":"x","status_code":500,"terminal_cause":"some_future_cause"}"#
    let decoded = try ProviderProtocolCodec.decodeProviderMessage(from: unknownJSON)
    guard case .inferenceError(let unknown) = decoded else {
        throw TestFailure.unexpectedMessage
    }
    #expect(unknown.terminalCause == nil)
    #expect(unknown.statusCode == 500)
    #expect(unknown.failureCode == nil)
    #expect(unknown.error == InferenceFailureCode.internalFailure.message)
}

@Test func inferenceErrorNeverEncodesLegacySecretText() throws {
    let secret = "PROMPT_SECRET https://private.invalid/path?token=raw"
    let legacyJSON = #"{"type":"inference_error","request_id":"r","error":"PROMPT_SECRET https://private.invalid/path?token=raw","status_code":500}"#
    let decoded = try ProviderProtocolCodec.decodeProviderMessage(from: legacyJSON)
    let reencoded = try ProviderProtocolCodec.encodeProviderMessage(decoded)
    let text = try #require(String(data: reencoded, encoding: .utf8))

    #expect(!text.contains(secret))
    #expect(text.contains(InferenceFailureCode.internalFailure.message))
}

@Test func desiredModelEntryCodableRoundTripUsesSnakeCaseKeys() throws {
    // Direct Codable round-trip of the entry struct (independent of the envelope):
    // proves the CodingKeys map to snake_case and previous_build omitempty parity.
    let withPrevious = CoordinatorMessage.DesiredModelEntry(
        modelName: "gemma-4-26b",
        desiredBuild: "build-desired",
        previousBuild: "build-previous"
    )
    let encoder = JSONEncoder()
    let data = try encoder.encode(withPrevious)
    let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(obj["model_name"] as? String == "gemma-4-26b")
    #expect(obj["desired_build"] as? String == "build-desired")
    #expect(obj["previous_build"] as? String == "build-previous")
    #expect(try JSONDecoder().decode(CoordinatorMessage.DesiredModelEntry.self, from: data) == withPrevious)

    // No previous_build → the key is omitted (Swift synthesized optional encode).
    let noPrevious = CoordinatorMessage.DesiredModelEntry(
        modelName: "qwen-0.6b",
        desiredBuild: "build-desired"
    )
    let noPrevData = try encoder.encode(noPrevious)
    let noPrevObj = try #require(try JSONSerialization.jsonObject(with: noPrevData) as? [String: Any])
    #expect(noPrevObj["previous_build"] == nil)
    #expect(noPrevObj.keys.contains("previous_build") == false)
    #expect(try JSONDecoder().decode(CoordinatorMessage.DesiredModelEntry.self, from: noPrevData) == noPrevious)
}


@Test func coordinatorMessagesDecodeAndEncodeWithSnakeCaseKeys() throws {
    let encryptedRequest = #"{"type":"inference_request","request_id":"go-enc-req-1","body":null,"encrypted_body":{"ephemeral_public_key":"ZXBoZW1lcmFs","ciphertext":"Y2lwaGVy"}}"#
    let request = try ProviderProtocolCodec.decodeCoordinatorMessage(from: encryptedRequest)
    guard case .inferenceRequest(let inferenceRequest) = request else {
        throw TestFailure.unexpectedMessage
    }
    #expect(inferenceRequest.requestId == "go-enc-req-1")
    #expect(inferenceRequest.body.isNull)
    #expect(inferenceRequest.encryptedBody?.ephemeralPublicKey == "ZXBoZW1lcmFs")

    let status = CoordinatorMessage.runtimeStatus(CoordinatorMessage.RuntimeStatus(
        verified: false,
        mismatches: [RuntimeMismatch(component: "runtime", expected: "good", got: "bad")]
    ))
    let encodedStatus = try ProviderProtocolCodec.encodeCoordinatorMessage(status)
    let object = try jsonObject(encodedStatus)
    #expect(object["type"] as? String == "runtime_status")
    #expect(object["verified"] as? Bool == false)
    #expect(object["mismatches"] != nil)
    #expect(try ProviderProtocolCodec.decodeCoordinatorMessage(from: encodedStatus) == status)
}

@Test func emptyOptionalCollectionsAreOmitted() throws {
    let heartbeat = ProviderMessage.heartbeat(ProviderMessage.Heartbeat(
        status: .idle,
        stats: ProviderStats(),
        systemMetrics: SystemMetrics(memoryPressure: 0, cpuUsage: 0, thermalState: .nominal)
    ))
    let heartbeatJSON = String(
        data: try ProviderProtocolCodec.encodeProviderMessage(heartbeat),
        encoding: .utf8
    ) ?? ""

    #expect(!heartbeatJSON.contains("active_model"))
    #expect(!heartbeatJSON.contains("warm_models"))
    #expect(!heartbeatJSON.contains("backend_capacity"))

    let runtimeStatus = CoordinatorMessage.runtimeStatus(CoordinatorMessage.RuntimeStatus(verified: true))
    let runtimeJSON = String(
        data: try ProviderProtocolCodec.encodeCoordinatorMessage(runtimeStatus),
        encoding: .utf8
    ) ?? ""
    #expect(!runtimeJSON.contains("mismatches"))
}

@Test func providerStatsOutcomeCountersRoundTripAndOmitZeroes() throws {
    let stats = ProviderStats(
        requestsServed: 11,
        tokensGenerated: 22,
        cancellationsReceived: 3,
        cancellationsBeforeOutput: 4,
        cancellationsPartialComplete: 5,
        generationErrorsAfterOutput: 6,
        chunkEncryptionErrors: 7,
        streamClosedWithoutTerminal: 8,
        cancelDuringModelLoad: 9,
        usageGaps: 10
    )

    let data = try JSONEncoder().encode(stats)
    let object = try jsonObject(data)

    #expect(object["requests_served"] as? Int == 11)
    #expect(object["tokens_generated"] as? Int == 22)
    #expect(object["cancellations_received"] as? Int == 3)
    #expect(object["cancellations_before_output"] as? Int == 4)
    #expect(object["cancellations_partial_complete"] as? Int == 5)
    #expect(object["generation_errors_after_output"] as? Int == 6)
    #expect(object["chunk_encryption_errors"] as? Int == 7)
    #expect(object["stream_closed_without_terminal"] as? Int == 8)
    #expect(object["cancel_during_model_load"] as? Int == 9)
    #expect(object["usage_gaps"] as? Int == 10)
    #expect(try JSONDecoder().decode(ProviderStats.self, from: data) == stats)

    let zeroObject = try jsonObject(JSONEncoder().encode(ProviderStats()))
    #expect(zeroObject["requests_served"] as? Int == 0)
    #expect(zeroObject["tokens_generated"] as? Int == 0)
    #expect(zeroObject["cancellations_received"] == nil)
    #expect(zeroObject["cancellations_before_output"] == nil)
    #expect(zeroObject["cancellations_partial_complete"] == nil)
    #expect(zeroObject["generation_errors_after_output"] == nil)
    #expect(zeroObject["chunk_encryption_errors"] == nil)
    #expect(zeroObject["stream_closed_without_terminal"] == nil)
    #expect(zeroObject["cancel_during_model_load"] == nil)
    #expect(zeroObject["usage_gaps"] == nil)

    let legacy = try JSONDecoder().decode(ProviderStats.self, from: Data(#"{}"#.utf8))
    #expect(legacy == ProviderStats())
}

@Test func backendSlotCapacityRoundTripsAdaptiveBatchingFields() throws {
    let slot = BackendSlotCapacity(
        model: "mlx-community/Qwen2.5-7B-4bit",
        state: "running",
        numRunning: 3,
        numWaiting: 2,
        activeTokens: 5_000,
        maxTokensPotential: 12_000,
        maxConcurrency: 6,
        observedDecodeTps: 85.5,
        observedPrefillTps: 412.0,
        activeTokenBudgetUsed: 28_000,
        activeTokenBudgetMax: 32_768,
        queuedTokenBudget: 4_096,
        kvBytesPerToken: 393_216,
        modelLoadTimeMs: 9_300
    )

    let data = try JSONEncoder().encode(slot)
    let object = try jsonObject(data)
    #expect(object["max_concurrency"] as? Int == 6)
    #expect(object["observed_decode_tps"] as? Double == 85.5)
    #expect(object["observed_prefill_tps"] as? Double == 412.0)
    #expect(object["active_token_budget_used"] as? Int == 28_000)
    #expect(object["active_token_budget_max"] as? Int == 32_768)
    #expect(object["queued_token_budget"] as? Int == 4_096)
    #expect(object["kv_bytes_per_token"] as? Int == 393_216)
    #expect(object["model_load_time_ms"] as? Int == 9_300)

    let decoded = try JSONDecoder().decode(BackendSlotCapacity.self, from: data)
    #expect(decoded == slot)
}

@Test func backendSlotCapacityDecodesMaxConcurrencyPresentAndNonzero() throws {
    let raw = #"{"model":"test","state":"running","num_running":2,"num_waiting":1,"active_tokens":3000,"max_tokens_potential":8000,"max_concurrency":4}"#
    let decoded = try JSONDecoder().decode(BackendSlotCapacity.self, from: Data(raw.utf8))

    #expect(decoded.maxConcurrency == 4)
}

@Test func backendSlotCapacityDecodesOldPayloadWithoutAdaptiveFields() throws {
    let raw = #"{"model":"test","state":"running","num_running":2,"num_waiting":0,"active_tokens":3000,"max_tokens_potential":8000}"#
    let decoded = try JSONDecoder().decode(BackendSlotCapacity.self, from: Data(raw.utf8))

    #expect(decoded.model == "test")
    #expect(decoded.numRunning == 2)
    #expect(decoded.maxConcurrency == 0)
    #expect(decoded.observedDecodeTps == 0)
    #expect(decoded.observedPrefillTps == 0)
    #expect(decoded.activeTokenBudgetUsed == 0)
    #expect(decoded.activeTokenBudgetMax == 0)
    #expect(decoded.queuedTokenBudget == 0)
    #expect(decoded.kvBytesPerToken == 0)
    #expect(decoded.modelLoadTimeMs == 0)
    // Pre-instrumentation provider: wedge fields default to zero/false.
    #expect(decoded.stepsExecuted == 0)
    #expect(decoded.admits == 0)
    #expect(decoded.firstTokensEmitted == 0)
    #expect(decoded.secondsSinceLastStep == 0)
    #expect(decoded.secondsSinceLastFirstToken == 0)
    #expect(decoded.wedgeSuspected == false)
    #expect(decoded.evalInFlightMs == 0)
    #expect(decoded.idleClearInFlightMs == 0)
}

@Test func backendSlotCapacityDecodesMaxConcurrencyZero() throws {
    let raw = #"{"model":"test","state":"running","num_running":2,"num_waiting":1,"active_tokens":3000,"max_tokens_potential":8000,"max_concurrency":0}"#
    let decoded = try JSONDecoder().decode(BackendSlotCapacity.self, from: Data(raw.utf8))

    #expect(decoded.maxConcurrency == 0)
}

@Test func backendSlotCapacityOmitsZeroAdditiveFields() throws {
    let slot = BackendSlotCapacity(
        model: "test",
        state: "running",
        numRunning: 1,
        numWaiting: 0,
        activeTokens: 0,
        maxTokensPotential: 0,
        maxConcurrency: 0,
        observedDecodeTps: 0,
        observedPrefillTps: 0,
        activeTokenBudgetUsed: 0,
        activeTokenBudgetMax: 0,
        queuedTokenBudget: 0,
        kvBytesPerToken: 0,
        modelLoadTimeMs: 0
    )

    let object = try jsonObject(JSONEncoder().encode(slot))

    #expect(object["active_tokens"] as? Int == 0)
    #expect(object["max_tokens_potential"] as? Int == 0)
    #expect(object["max_concurrency"] == nil)
    #expect(object["observed_decode_tps"] == nil)
    #expect(object["observed_prefill_tps"] == nil)
    #expect(object["active_token_budget_used"] == nil)
    #expect(object["active_token_budget_max"] == nil)
    #expect(object["queued_token_budget"] == nil)
    #expect(object["kv_bytes_per_token"] == nil)
    #expect(object["model_load_time_ms"] == nil)
    // Wedge fields default to zero/false and must be omitted too.
    #expect(object["steps_executed"] == nil)
    #expect(object["admits"] == nil)
    #expect(object["first_tokens_emitted"] == nil)
    #expect(object["seconds_since_last_step"] == nil)
    #expect(object["seconds_since_last_first_token"] == nil)
    #expect(object["wedge_suspected"] == nil)
    #expect(object["eval_in_flight_ms"] == nil)
    #expect(object["idle_clear_in_flight_ms"] == nil)
}

@Test func backendSlotCapacityRoundTripsWedgeFields() throws {
    // The wedge signature: admits climbing, 0 first tokens, steps frozen.
    let slot = BackendSlotCapacity(
        model: "gpt-oss-20b",
        state: "running",
        numRunning: 0,
        numWaiting: 0,
        activeTokens: 0,
        maxTokensPotential: 0,
        stepsExecuted: 4321,
        admits: 7,
        firstTokensEmitted: 0,
        secondsSinceLastStep: 12.5,
        secondsSinceLastFirstToken: 13.0,
        wedgeSuspected: true,
        evalInFlightMs: 11_000,
        idleClearInFlightMs: 1_500
    )

    let data = try JSONEncoder().encode(slot)
    let object = try jsonObject(data)
    #expect(object["steps_executed"] as? Int == 4321)
    #expect(object["admits"] as? Int == 7)
    // 0 first tokens is the wedge signal — omitted on the wire (its ABSENCE,
    // paired with admits>0, is what reveals the wedge).
    #expect(object["first_tokens_emitted"] == nil)
    #expect(object["seconds_since_last_step"] as? Double == 12.5)
    #expect(object["seconds_since_last_first_token"] as? Double == 13.0)
    #expect(object["wedge_suspected"] as? Bool == true)
    #expect(object["eval_in_flight_ms"] as? Int == 11_000)
    #expect(object["idle_clear_in_flight_ms"] as? Int == 1_500)

    let decoded = try JSONDecoder().decode(BackendSlotCapacity.self, from: data)
    #expect(decoded == slot)
}

@Test func privacyCapabilitiesJSONOmitsHypervisorKeys() throws {
    // The hypervisor concept was removed from the provider (it never uses
    // hypervisors; the old field was a hardcoded-false trust signal). Pin
    // that registration privacy_capabilities JSON carries NO hypervisor key.
    let data = try JSONEncoder().encode(samplePrivacyCapabilities())
    let object = try jsonObject(data)

    #expect(object["hypervisor_active"] == nil)
    #expect(object["hypervisorActive"] == nil)
    // Sanity: the remaining capabilities still encode under snake_case keys.
    #expect(object["text_backend_inprocess"] as? Bool == true)
    #expect(object["env_scrubbed"] as? Bool == true)
    #expect(object.count == 8)
}

@Test func attestationResponseJSONOmitsHypervisorKeys() throws {
    // Challenge-response wire shape: no hypervisor_active key, ever -- the
    // canonical status bytes (StatusCanonical) omit it too, so the coordinator
    // and provider sign/verify the same bytes.
    let message = ProviderMessage.attestationResponse(ProviderMessage.AttestationResponse(
        nonce: "bm9uY2U=",
        signature: "c2ln",
        statusSignature: "c3RhdHVz",
        publicKey: "cGs=",
        rdmaDisabled: true,
        sipEnabled: true,
        secureBootEnabled: true,
        binaryHash: "binaryhash",
        activeModelHash: "modelhash",
        runtimeHash: "runtimehash",
        templateHashes: ["chatml": "templatehash"],
        modelHashes: ["model": "weighthash"]
    ))
    let data = try ProviderProtocolCodec.encodeProviderMessage(message)
    let object = try jsonObject(data)

    #expect(object["hypervisor_active"] == nil)
    #expect(object["hypervisorActive"] == nil)
    // Sanity: the posture fields that remain still ride the response.
    #expect(object["rdma_disabled"] as? Bool == true)
    #expect(object["sip_enabled"] as? Bool == true)
}

@Test func heartbeatBackendCapacityEncodesSnakeCaseFields() throws {
    let heartbeat = ProviderMessage.heartbeat(ProviderMessage.Heartbeat(
        status: .serving,
        activeModel: "mlx-community/Qwen2.5-7B-4bit",
        stats: ProviderStats(requestsServed: 1, tokensGenerated: 2),
        systemMetrics: SystemMetrics(memoryPressure: 0.1, cpuUsage: 0.2, thermalState: .nominal),
        backendCapacity: BackendCapacity(
            slots: [BackendSlotCapacity(
                model: "mlx-community/Qwen2.5-7B-4bit",
                state: "running",
                numRunning: 1,
                numWaiting: 2,
                activeTokens: 3000,
                maxTokensPotential: 8000,
                maxConcurrency: 4,
                observedDecodeTps: 90,
                observedPrefillTps: 360,
                activeTokenBudgetUsed: 5000,
                activeTokenBudgetMax: 12000,
                queuedTokenBudget: 7000,
                kvBytesPerToken: 262144,
                modelLoadTimeMs: 8200
            )],
            gpuMemoryActiveGb: 5.5,
            gpuMemoryPeakGb: 6.5,
            gpuMemoryCacheGb: 1.5,
            totalMemoryGb: 36,
            mlxCacheReclaimer: MLXCacheReclaimerTelemetry(
                cacheLimitBytes: 8 * 1024 * 1024 * 1024,
                sweepSignals: 12,
                reclaims: 4,
                reclaimedBytes: 24 * 1024 * 1024 * 1024,
                lastReclaimedBytes: 6 * 1024 * 1024 * 1024,
                lastReclaimDurationMs: 17)
        )
    ))

    let data = try ProviderProtocolCodec.encodeProviderMessage(heartbeat)
    let object = try jsonObject(data)
    let capacity = object["backend_capacity"] as? [String: Any]
    let slot = (capacity?["slots"] as? [[String: Any]])?.first
    let reclaimer = capacity?["mlx_cache_reclaimer"] as? [String: Any]

    #expect(capacity?["gpu_memory_active_gb"] as? Double == 5.5)
    #expect(capacity?["gpu_memory_peak_gb"] as? Double == 6.5)
    #expect(capacity?["gpu_memory_cache_gb"] as? Double == 1.5)
    #expect(capacity?["total_memory_gb"] as? Double == 36)
    #expect((reclaimer?["cache_limit_bytes"] as? NSNumber)?.uint64Value == UInt64(8) * 1024 * 1024 * 1024)
    #expect(reclaimer?["sweep_signals"] as? Int == 12)
    #expect(reclaimer?["reclaims"] as? Int == 4)
    #expect((reclaimer?["reclaimed_bytes"] as? NSNumber)?.uint64Value == UInt64(24) * 1024 * 1024 * 1024)
    #expect((reclaimer?["last_reclaimed_bytes"] as? NSNumber)?.uint64Value == UInt64(6) * 1024 * 1024 * 1024)
    #expect(reclaimer?["last_reclaim_duration_ms"] as? Int == 17)
    #expect(slot?["num_running"] as? Int == 1)
    #expect(slot?["num_waiting"] as? Int == 2)
    #expect(slot?["active_tokens"] as? Int == 3000)
    #expect(slot?["max_tokens_potential"] as? Int == 8000)
    #expect(slot?["max_concurrency"] as? Int == 4)
    #expect(slot?["observed_decode_tps"] as? Double == 90)
    #expect(slot?["observed_prefill_tps"] as? Double == 360)
    #expect(slot?["active_token_budget_used"] as? Int == 5000)
    #expect(slot?["active_token_budget_max"] as? Int == 12000)
    #expect(slot?["queued_token_budget"] as? Int == 7000)
    #expect(slot?["kv_bytes_per_token"] as? Int == 262144)
    #expect(slot?["model_load_time_ms"] as? Int == 8200)
}

@Test func heartbeatAPNsTokenRoundTripsAndOmitsWhenAbsent() throws {
    // W5 Fix 2: with a token, the snake_case fields are present and round-trip.
    let withToken = ProviderMessage.heartbeat(ProviderMessage.Heartbeat(
        status: .idle,
        stats: ProviderStats(),
        systemMetrics: SystemMetrics(memoryPressure: 0, cpuUsage: 0, thermalState: .nominal),
        apnsDeviceToken: "cb1ceb489ec9",
        apnsEnvironment: "production"
    ))
    let data = try ProviderProtocolCodec.encodeProviderMessage(withToken)
    let object = try jsonObject(data)
    #expect(object["apns_device_token"] as? String == "cb1ceb489ec9")
    #expect(object["apns_environment"] as? String == "production")
    #expect(try ProviderProtocolCodec.decodeProviderMessage(from: data) == withToken)

    // Without a token (steady state / legacy): both fields omitted — omitempty
    // parity with the Go HeartbeatMessage, or the symmetry tests drift.
    let noToken = ProviderMessage.heartbeat(ProviderMessage.Heartbeat(
        status: .idle,
        stats: ProviderStats(),
        systemMetrics: SystemMetrics(memoryPressure: 0, cpuUsage: 0, thermalState: .nominal)
    ))
    let noTokenJSON = String(
        data: try ProviderProtocolCodec.encodeProviderMessage(noToken),
        encoding: .utf8
    ) ?? ""
    #expect(!noTokenJSON.contains("apns_device_token"))
    #expect(!noTokenJSON.contains("apns_environment"))
}

@Test func prefixCacheProtocolCapabilityEncodesOnBothRegistrationPaths() throws {
    func message(attestation: RawJSON?) -> ProviderMessage {
        .register(ProviderMessage.Register(
            hardware: sampleHardware(),
            models: [sampleModel()],
            backend: "mlx_swift_lm",
            attestation: attestation,
            prefixCacheProtocol: 1))
    }
    for attestation in [nil, RawJSON(rawBytes: Data(#"{"ok":true}"#.utf8))] {
        let data = try ProviderProtocolCodec.encodeProviderMessage(message(attestation: attestation))
        let object = try jsonObject(data)
        #expect(object["prefix_cache_protocol"] as? Int == 1)
        guard case .register(let decoded) = try ProviderProtocolCodec.decodeProviderMessage(from: data)
        else { throw TestFailure.unexpectedMessage }
        #expect(decoded.prefixCacheProtocol == 1)
    }

    let legacy = ProviderMessage.register(ProviderMessage.Register(
        hardware: sampleHardware(), models: [], backend: "mlx_swift_lm"))
    #expect(try jsonObject(ProviderProtocolCodec.encodeProviderMessage(legacy))["prefix_cache_protocol"] == nil)
}

@Test func prefixCacheReceiptMessagesMatchWireContract() throws {
    let lookup = ProviderMessage.prefixCacheLookup(.init(
        requestId: "req-1",
        cacheReceiptNonce: "nonce-1",
        outcome: .hit,
        tier: .ssd,
        cachedTokens: 4096,
        prefillTokensSaved: 2560,
        stageMs: 12.5))
    let ready = ProviderMessage.prefixCacheReady(.init(
        requestId: "req-1",
        cacheReceiptNonce: "nonce-1",
        readyTokens: 8192,
        requiredRecomputeTokens: 1536,
        expectedPrefillTokensSaved: 6656,
        tier: .ssd,
        stageMs: 18.75))
    for message in [lookup, ready] {
        let data = try ProviderProtocolCodec.encodeProviderMessage(message)
        #expect(try ProviderProtocolCodec.decodeProviderMessage(from: data) == message)
    }
    let lookupObject = try jsonObject(ProviderProtocolCodec.encodeProviderMessage(lookup))
    #expect(lookupObject["type"] as? String == "prefix_cache_lookup")
    #expect(lookupObject["cache_receipt_nonce"] as? String == "nonce-1")
    #expect(lookupObject["outcome"] as? String == "hit")
    #expect(lookupObject["cached_tokens"] as? Int == 4096)
    #expect(lookupObject["prefill_tokens_saved"] as? Int == 2560)
    let readyObject = try jsonObject(ProviderProtocolCodec.encodeProviderMessage(ready))
    #expect(readyObject["type"] as? String == "prefix_cache_ready")
    #expect(readyObject["ready_tokens"] as? Int == 8192)
    #expect(readyObject["required_recompute_tokens"] as? Int == 1536)
    #expect(readyObject["stage_ms"] as? Double == 18.75)

    let legacyReadyJSON = #"{"type":"prefix_cache_ready","request_id":"r","cache_receipt_nonce":"n","ready_tokens":8,"required_recompute_tokens":0,"expected_prefill_tokens_saved":8,"tier":"ssd"}"#
    guard case .prefixCacheReady(let legacyReady) = try ProviderProtocolCodec.decodeProviderMessage(
        from: Data(legacyReadyJSON.utf8))
    else { throw TestFailure.unexpectedMessage }
    #expect(legacyReady.stageMs == nil)
}

@Test func usageInfoCacheFieldsAreOptionalAndBackwardCompatible() throws {
    let legacy = UsageInfo(promptTokens: 10, completionTokens: 2)
    let legacyObject = try jsonObject(JSONEncoder().encode(legacy))
    #expect(legacyObject["cache_outcome"] == nil)
    #expect(legacyObject["cache_tier"] == nil)
    #expect(legacyObject["cached_tokens"] == nil)
    #expect(legacyObject["prefill_tokens_saved"] == nil)
    #expect(legacyObject["cache_stage_ms"] == nil)

    let detailed = UsageInfo(
        promptTokens: 5000,
        completionTokens: 20,
        cacheOutcome: .missCorrupt,
        cacheTier: .ssd,
        cachedTokens: 0,
        prefillTokensSaved: 0,
        cacheStageMs: 4.25)
    let encoded = try JSONEncoder().encode(detailed)
    let object = try jsonObject(encoded)
    #expect(object["cache_outcome"] as? String == "miss_corrupt")
    #expect(object["cache_tier"] as? String == "ssd")
    #expect(object["cached_tokens"] as? Int == 0)
    #expect(object["cache_stage_ms"] as? Double == 4.25)
    #expect(try JSONDecoder().decode(UsageInfo.self, from: encoded) == detailed)
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

private func sampleModel() -> ModelInfo {
    ModelInfo(
        id: "mlx-community/Qwen2.5-7B-4bit",
        modelType: "qwen2",
        parameters: nil,
        quantization: "4bit",
        sizeBytes: 4_000_000_000,
        estimatedMemoryGb: 4.5
    )
}

private func samplePrivacyCapabilities() -> PrivacyCapabilities {
    PrivacyCapabilities(
        textBackendInprocess: true,
        textProxyDisabled: true,
        pythonRuntimeLocked: true,
        dangerousModulesBlocked: true,
        sipEnabled: true,
        antiDebugEnabled: true,
        coreDumpsDisabled: true,
        envScrubbed: true
    )
}

@Test func usageInfoEncodesReasoningTokensAndDecodesLegacyPayload() throws {
    // Encoding includes the snake_case reasoning_tokens key.
    let usage = UsageInfo(promptTokens: 10, completionTokens: 30, reasoningTokens: 12)
    let encoded = try JSONEncoder().encode(usage)
    let obj = try jsonObject(encoded)
    #expect((obj["prompt_tokens"] as? Int) == 10)
    #expect((obj["completion_tokens"] as? Int) == 30)
    #expect((obj["reasoning_tokens"] as? Int) == 12)

    // Round-trips.
    let decoded = try JSONDecoder().decode(UsageInfo.self, from: encoded)
    #expect(decoded == usage)

    // Backward-compat: a legacy payload without reasoning_tokens decodes
    // with the field defaulting to 0.
    let legacy = #"{"prompt_tokens":5,"completion_tokens":7}"#
    let legacyDecoded = try JSONDecoder().decode(UsageInfo.self, from: Data(legacy.utf8))
    #expect(legacyDecoded.promptTokens == 5)
    #expect(legacyDecoded.completionTokens == 7)
    #expect(legacyDecoded.reasoningTokens == 0)
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private enum TestFailure: Error {
    case unexpectedMessage
}
