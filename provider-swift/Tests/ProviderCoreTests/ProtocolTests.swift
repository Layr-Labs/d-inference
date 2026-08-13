import Foundation
import Testing
@testable import ProviderCore

@Test func prefixCacheV2CapabilityIsExplicitAndLegacyOmissionIsStable() throws {
    let legacy = ProviderMessage.register(ProviderMessage.Register(
        hardware: sampleHardware(),
        models: [sampleModel()],
        backend: "mlx_swift_lm",
        prefixCacheProtocol: 1))
    let legacyObject = try jsonObject(
        try ProviderProtocolCodec.encodeProviderMessage(legacy))
    #expect(legacyObject["prefix_cache_v2_models"] == nil)

    let capability = PrefixCacheV2Capability(
        modelId: "model",
        modelAggregateHash: String(repeating: "a", count: 64),
        promptContractId: String(repeating: "b", count: 64),
        blockHashVersion: "dbk3",
        blockSize: 256,
        cacheEpoch: "11111111-1111-1111-1111-111111111111",
        enabled: true,
        ready: true)
    let v2 = ProviderMessage.register(ProviderMessage.Register(
        hardware: sampleHardware(),
        models: [sampleModel()],
        backend: "mlx_swift_lm",
        prefixCacheProtocol: 2,
        prefixCacheV2Models: [capability]))
    let data = try ProviderProtocolCodec.encodeProviderMessage(v2)
    let object = try jsonObject(data)
    #expect(object["prefix_cache_protocol"] as? Int == 2)
    #expect((object["prefix_cache_v2_models"] as? [[String: Any]])?.count == 1)
    guard case .register(let decoded) =
        try ProviderProtocolCodec.decodeProviderMessage(from: data)
    else {
        throw TestFailure.unexpectedMessage
    }
    #expect(decoded.prefixCacheV2Models == [capability])
}

@Test func prefixCacheTelemetrySnapshotsAreOptionalBoundedWireEnums() throws {
    let legacy = ProviderMessage.heartbeat(ProviderMessage.Heartbeat(
        status: .idle,
        stats: ProviderStats(),
        systemMetrics: SystemMetrics(
            memoryPressure: 0, cpuUsage: 0, thermalState: .nominal)))
    let legacyObject = try jsonObject(
        try ProviderProtocolCodec.encodeProviderMessage(legacy))
    #expect(legacyObject["prefix_cache_statuses"] == nil)
    #expect(legacyObject["prefix_cache_donation_outcomes"] == nil)

    let status = PrefixCacheModelStatus(
        modelId: "model",
        backend: .contiguous,
        replayStrategy: .frozenFull,
        state: .disabled,
        reason: .weightHashUnavailable)
    let current = ProviderMessage.heartbeat(ProviderMessage.Heartbeat(
        status: .idle,
        stats: ProviderStats(),
        systemMetrics: SystemMetrics(
            memoryPressure: 0, cpuUsage: 0, thermalState: .nominal),
        prefixCacheProtocol: 1,
        prefixCacheV2Models: [],
        prefixCacheStatuses: [status],
        prefixCacheDonationOutcomes: [
            PrefixCacheDonationOutcomeCount(outcome: .writeQueueFull, count: 3)
        ]))
    let data = try ProviderProtocolCodec.encodeProviderMessage(current)
    let object = try jsonObject(data)
    let statusObject = try #require(
        (object["prefix_cache_statuses"] as? [[String: Any]])?.first)
    #expect(statusObject["replay_strategy"] as? String == "frozen_full")
    #expect(statusObject["reason"] as? String == "weight_hash_unavailable")
    let outcomeObject = try #require(
        (object["prefix_cache_donation_outcomes"] as? [[String: Any]])?.first)
    #expect(outcomeObject["outcome"] as? String == "write_queue_full")
    #expect(outcomeObject["count"] as? Int == 3)

    guard case .heartbeat(let decoded) =
        try ProviderProtocolCodec.decodeProviderMessage(from: data)
    else {
        throw TestFailure.unexpectedMessage
    }
    #expect(decoded.prefixCacheStatuses == [status])
    #expect(decoded.prefixCacheDonationOutcomes == [
        PrefixCacheDonationOutcomeCount(outcome: .writeQueueFull, count: 3)
    ])
}

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
            error: "model not loaded",
            statusCode: 503
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
        error: "(Jinja.TemplateException error 1.)",
        statusCode: 500,
        errorReason: "jinja_channel_tags"
    ))
    let withData = try ProviderProtocolCodec.encodeProviderMessage(withReason)
    let withObject = try jsonObject(withData)
    #expect(withObject["error_reason"] as? String == "jinja_channel_tags")

    let decodedWith = try ProviderProtocolCodec.decodeProviderMessage(from: withData)
    #expect(decodedWith == withReason)
    guard case .inferenceError(let e) = decodedWith else { throw TestFailure.unexpectedMessage }
    #expect(e.errorReason == "jinja_channel_tags")

    // Absent (nil) → the key is OMITTED on the wire (mirrors Go `omitempty`) and
    // round-trips back to nil.
    let withoutReason = ProviderMessage.inferenceError(ProviderMessage.InferenceError(
        requestId: "req-error",
        error: "model not loaded",
        statusCode: 503
    ))
    let withoutData = try ProviderProtocolCodec.encodeProviderMessage(withoutReason)
    let withoutObject = try jsonObject(withoutData)
    #expect(withoutObject["error_reason"] == nil)

    let decodedWithout = try ProviderProtocolCodec.decodeProviderMessage(from: withoutData)
    #expect(decodedWithout == withoutReason)
    guard case .inferenceError(let e2) = decodedWithout else { throw TestFailure.unexpectedMessage }
    #expect(e2.errorReason == nil)
}

@Test func inferenceErrorEncodesTypedTerminalFieldsOnlyWhenPresent() throws {
    // Deadline-first-principles: the optional `terminal_cause` + `attempt_usage`
    // fields ride the existing inference_error message and mirror the Go side
    // (`coordinator/protocol/messages.go`) exactly.
    //
    // Present → snake_case keys on the wire, round-trip back to the values.
    let withTerminal = ProviderMessage.inferenceError(ProviderMessage.InferenceError(
        requestId: "req-term",
        error: "decode_stall: decode made no confirmed token progress",
        statusCode: 500,
        terminalCause: .decodeStall,
        attemptUsage: UsageInfo(promptTokens: 7, completionTokens: 42)
    ))
    let withData = try ProviderProtocolCodec.encodeProviderMessage(withTerminal)
    let withObject = try jsonObject(withData)
    #expect(withObject["terminal_cause"] as? String == "decode_stall")
    let usageObject = withObject["attempt_usage"] as? [String: Any]
    #expect(usageObject?["prompt_tokens"] as? Int == 7)
    #expect(usageObject?["completion_tokens"] as? Int == 42)
    // reasoning_tokens is 0 here → omitted (mirrors Go `omitempty`).
    #expect(usageObject?["reasoning_tokens"] == nil)

    let decodedWith = try ProviderProtocolCodec.decodeProviderMessage(from: withData)
    #expect(decodedWith == withTerminal)
    guard case .inferenceError(let e) = decodedWith else { throw TestFailure.unexpectedMessage }
    #expect(e.terminalCause == .decodeStall)
    #expect(e.attemptUsage?.promptTokens == 7)
    #expect(e.attemptUsage?.completionTokens == 42)

    // Absent (legacy) → BOTH keys omitted AND the full serialized shape is
    // byte-identical to the pre-fix message (the Go side asserts the same
    // legacy bytes). Encoder uses sorted keys, so the string is deterministic.
    let legacy = ProviderMessage.inferenceError(ProviderMessage.InferenceError(
        requestId: "req-error",
        error: "model not loaded",
        statusCode: 503
    ))
    let legacyData = try ProviderProtocolCodec.encodeProviderMessage(legacy)
    let legacyString = String(data: legacyData, encoding: .utf8)
    #expect(
        legacyString
            == #"{"error":"model not loaded","request_id":"req-error","status_code":503,"type":"inference_error"}"#)
    let legacyObject = try jsonObject(legacyData)
    #expect(legacyObject["terminal_cause"] == nil)
    #expect(legacyObject["attempt_usage"] == nil)
    #expect(try ProviderProtocolCodec.decodeProviderMessage(from: legacyData) == legacy)

    // Unknown terminal_cause string → tolerant decode (nil), never a throw; a
    // newer provider value must not crash an older decoder.
    let unknownJSON = #"{"type":"inference_error","request_id":"r","error":"x","status_code":500,"terminal_cause":"some_future_cause"}"#
    let decodedUnknown = try ProviderProtocolCodec.decodeProviderMessage(from: unknownJSON)
    guard case .inferenceError(let unknown) = decodedUnknown else {
        throw TestFailure.unexpectedMessage
    }
    #expect(unknown.terminalCause == nil)
    #expect(unknown.statusCode == 500)
}

@Test func loadModelMessagesRoundTripWithCoordinator() throws {
    // Coordinator → provider preload request
    let goLoadRequest = #"{"type":"load_model","model_id":"mlx-community/Qwen3-0.6B-8bit"}"#
    let decoded = try ProviderProtocolCodec.decodeCoordinatorMessage(from: goLoadRequest)
    guard case .loadModel(let load) = decoded else {
        throw TestFailure.unexpectedMessage
    }
    #expect(load.modelId == "mlx-community/Qwen3-0.6B-8bit")

    // Provider → coordinator status replies (covers all three lifecycle states)
    let replies: [ProviderMessage] = [
        .loadModelStatus(ProviderMessage.LoadModelStatus(
            modelId: "mlx-community/Qwen3-0.6B-8bit",
            status: .started
        )),
        .loadModelStatus(ProviderMessage.LoadModelStatus(
            modelId: "mlx-community/Qwen3-0.6B-8bit",
            status: .succeeded
        )),
        .loadModelStatus(ProviderMessage.LoadModelStatus(
            modelId: "mlx-community/Qwen3-0.6B-8bit",
            status: .failed,
            error: "model not in local cache"
        )),
    ]

    for reply in replies {
        let encoded = try ProviderProtocolCodec.encodeProviderMessage(reply)
        let object = try jsonObject(encoded)
        #expect(object["type"] as? String == "load_model_status")
        #expect(object["model_id"] as? String == "mlx-community/Qwen3-0.6B-8bit")

        let roundTripped = try ProviderProtocolCodec.decodeProviderMessage(from: encoded)
        #expect(roundTripped == reply)
    }

    // Failed status must surface the error string on the wire.
    let failed: ProviderMessage = .loadModelStatus(ProviderMessage.LoadModelStatus(
        modelId: "model-x",
        status: .failed,
        error: "GPU OOM"
    ))
    let failedData = try ProviderProtocolCodec.encodeProviderMessage(failed)
    let failedObj = try jsonObject(failedData)
    #expect(failedObj["status"] as? String == "failed")
    #expect(failedObj["error"] as? String == "GPU OOM")
}

@Test func prefetchModelMessagesRoundTripWithCoordinator() throws {
    // Coordinator → provider prefetch request (decode a Go-emitted wire form).
    let goPrefetchRequest = #"{"type":"prefetch_model","model_id":"mlx-community/gemma-4-26B-A4B-it-qat-4bit","priority":5}"#
    let decoded = try ProviderProtocolCodec.decodeCoordinatorMessage(from: goPrefetchRequest)
    guard case .prefetchModel(let pf) = decoded else {
        throw TestFailure.unexpectedMessage
    }
    #expect(pf.modelId == "mlx-community/gemma-4-26B-A4B-it-qat-4bit")
    #expect(pf.priority == 5)

    // priority is omitempty on the Go side: a request without it decodes to 0.
    let noPriority = #"{"type":"prefetch_model","model_id":"m"}"#
    guard case .prefetchModel(let pf0) = try ProviderProtocolCodec.decodeCoordinatorMessage(from: noPriority) else {
        throw TestFailure.unexpectedMessage
    }
    #expect(pf0.priority == 0)

    // Encoding a zero priority must omit the key (byte-compatible with Go).
    let zeroEncoded = try ProviderProtocolCodec.encodeCoordinatorMessage(
        .prefetchModel(CoordinatorMessage.PrefetchModel(modelId: "m"))
    )
    #expect(try jsonObject(zeroEncoded)["priority"] == nil)

    // Provider → coordinator status replies across the full lifecycle.
    let model = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
    let replies: [ProviderMessage] = [
        .prefetchModelStatus(ProviderMessage.PrefetchModelStatus(modelId: model, status: .started)),
        .prefetchModelStatus(ProviderMessage.PrefetchModelStatus(
            modelId: model, status: .downloading, bytesDone: 1_048_576, bytesTotal: 15_600_000_000)),
        .prefetchModelStatus(ProviderMessage.PrefetchModelStatus(modelId: model, status: .verified)),
        .prefetchModelStatus(ProviderMessage.PrefetchModelStatus(
            modelId: model, status: .failed, error: "hash mismatch")),
    ]
    for reply in replies {
        let encoded = try ProviderProtocolCodec.encodeProviderMessage(reply)
        let object = try jsonObject(encoded)
        #expect(object["type"] as? String == "prefetch_model_status")
        #expect(object["model_id"] as? String == model)
        let roundTripped = try ProviderProtocolCodec.decodeProviderMessage(from: encoded)
        #expect(roundTripped == reply)
    }

    // Progress fields appear only when non-zero; verified carries neither.
    let downloading = try jsonObject(try ProviderProtocolCodec.encodeProviderMessage(replies[1]))
    #expect(downloading["bytes_done"] as? Int64 == 1_048_576)
    #expect(downloading["bytes_total"] as? Int64 == 15_600_000_000)
    let verified = try jsonObject(try ProviderProtocolCodec.encodeProviderMessage(replies[2]))
    #expect(verified["bytes_done"] == nil)
    #expect(verified["bytes_total"] == nil)
    #expect(verified["error"] == nil)
}

@Test func desiredModelsMessageRoundTripsWithCoordinator() throws {
    // Coordinator → provider declarative desired-state (decode a Go-emitted wire
    // form). model_name / desired_build / previous_build are snake_case; the
    // first entry carries a previous build (mid-rollout), the second does not.
    let goDesired = #"{"type":"desired_models","models":[{"model_name":"gemma-4-26b","desired_build":"mlx-community/gemma-4-26B-A4B-it-qat-4bit","previous_build":"mlx-community/gemma-4-26B-A4B-it-fp8"},{"model_name":"qwen-0.6b","desired_build":"mlx-community/Qwen3-0.6B-8bit"}]}"#
    let decoded = try ProviderProtocolCodec.decodeCoordinatorMessage(from: goDesired)
    guard case .desiredModels(let desired) = decoded else {
        throw TestFailure.unexpectedMessage
    }
    #expect(desired.models.count == 2)
    #expect(desired.models[0].modelName == "gemma-4-26b")
    #expect(desired.models[0].desiredBuild == "mlx-community/gemma-4-26B-A4B-it-qat-4bit")
    #expect(desired.models[0].previousBuild == "mlx-community/gemma-4-26B-A4B-it-fp8")
    // omitempty parity: a Go entry without previous_build decodes to nil.
    #expect(desired.models[1].modelName == "qwen-0.6b")
    #expect(desired.models[1].desiredBuild == "mlx-community/Qwen3-0.6B-8bit")
    #expect(desired.models[1].previousBuild == nil)

    // Re-encode and confirm the wire shape: snake_case keys, previous_build
    // present only on the first entry (omitempty ↔ Swift optional parity), and a
    // full structural round-trip back to the same value.
    let encoded = try ProviderProtocolCodec.encodeCoordinatorMessage(decoded)
    let object = try jsonObject(encoded)
    #expect(object["type"] as? String == "desired_models")
    let models = try #require(object["models"] as? [[String: Any]])
    #expect(models.count == 2)
    #expect(models[0]["model_name"] as? String == "gemma-4-26b")
    #expect(models[0]["desired_build"] as? String == "mlx-community/gemma-4-26B-A4B-it-qat-4bit")
    #expect(models[0]["previous_build"] as? String == "mlx-community/gemma-4-26B-A4B-it-fp8")
    // Second entry omits previous_build entirely (nil optional → absent key).
    #expect(models[1]["previous_build"] == nil)
    #expect(models[1]["desired_build"] as? String == "mlx-community/Qwen3-0.6B-8bit")
    #expect(try ProviderProtocolCodec.decodeCoordinatorMessage(from: encoded) == decoded)

    // An empty/absent models array decodes to an empty list (no crash).
    let empty = try ProviderProtocolCodec.decodeCoordinatorMessage(from: #"{"type":"desired_models"}"#)
    guard case .desiredModels(let emptyDesired) = empty else {
        throw TestFailure.unexpectedMessage
    }
    #expect(emptyDesired.models.isEmpty)
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

@Test func modelsUpdateRoundTripsAndReusesModelInfoEncoding() throws {
    // A verified prefetch advertises the authoritative ModelInfo (incl. the
    // computed weight hash) out-of-band so the coordinator can cross-check it
    // before routing. The wire form reuses the SAME ModelInfo shape as
    // register's models[]: {"type":"models_update","models":[{...}]}.
    let info = ModelInfo(
        id: "mlx-community/gemma-4-26B-A4B-it-qat-4bit",
        modelType: "gemma3",
        quantization: "4bit",
        sizeBytes: 15_600_000_000,
        estimatedMemoryGb: 16.0,
        weightHash: String(repeating: "ab", count: 32)
    )
    let message: ProviderMessage = .modelsUpdate(ProviderMessage.ModelsUpdate(models: [info]))

    let encoded = try ProviderProtocolCodec.encodeProviderMessage(message)
    let object = try jsonObject(encoded)
    #expect(object["type"] as? String == "models_update")

    // models[] carries the snake_case ModelInfo fields including weight_hash.
    let models = try #require(object["models"] as? [[String: Any]])
    #expect(models.count == 1)
    let m = models[0]
    #expect(m["id"] as? String == info.id)
    #expect(m["model_type"] as? String == "gemma3")
    #expect(m["quantization"] as? String == "4bit")
    #expect((m["size_bytes"] as? NSNumber)?.int64Value == 15_600_000_000)
    #expect(m["weight_hash"] as? String == info.weightHash)

    // Full round-trip through the Codable envelope preserves the message.
    let decoded = try ProviderProtocolCodec.decodeProviderMessage(from: encoded)
    #expect(decoded == message)

    // Decodes a Go-emitted wire form too (forward compat with the coordinator).
    let goWire = #"{"type":"models_update","models":[{"id":"org/m","size_bytes":1024,"estimated_memory_gb":1.5,"weight_hash":"deadbeef"}]}"#
    guard case .modelsUpdate(let u) = try ProviderProtocolCodec.decodeProviderMessage(from: goWire) else {
        throw TestFailure.unexpectedMessage
    }
    #expect(u.models.count == 1)
    #expect(u.models[0].id == "org/m")
    #expect(u.models[0].weightHash == "deadbeef")
}

@Test func lmStudioModelsUpdateRoundTrips() throws {
    let info = ModelInfo(
        id: "lmstudio/laguna-s-2.1-nvfp4-mlx",
        modelType: "chat",
        quantization: "4bit",
        sizeBytes: 71_905_944_629,
        estimatedMemoryGb: 67
    )
    let message: ProviderMessage = .lmStudioModelsUpdate(
        ProviderMessage.LMStudioModelsUpdate(models: [info])
    )

    let encoded = try ProviderProtocolCodec.encodeProviderMessage(message)
    let object = try jsonObject(encoded)
    #expect(object["type"] as? String == "lmstudio_models_update")
    #expect(try ProviderProtocolCodec.decodeProviderMessage(from: encoded) == message)
}

@Test func modelInfoTemplateRenderOKTriState() throws {
    // Wire contract (shared with coordinator/protocol/messages.go):
    // `template_render_ok` is tri-state — absent (old provider / check
    // didn't run), true (all fixtures render), false (some fixture threw).
    // FALSE MUST GO ON THE WIRE: it is the routing signal. This differs
    // from `is_vision`, which encodes only-true.
    let encoder = JSONEncoder()

    // true → encoded as true, round-trips.
    var info = ModelInfo(id: "org/m", sizeBytes: 1024, estimatedMemoryGb: 1.5, templateRenderOK: true)
    var obj = try #require(try JSONSerialization.jsonObject(with: encoder.encode(info)) as? [String: Any])
    #expect(obj["template_render_ok"] as? Bool == true)
    #expect(try JSONDecoder().decode(ModelInfo.self, from: encoder.encode(info)) == info)

    // false → STILL encoded (the signal), round-trips as false.
    info = ModelInfo(id: "org/m", sizeBytes: 1024, estimatedMemoryGb: 1.5, templateRenderOK: false)
    obj = try #require(try JSONSerialization.jsonObject(with: encoder.encode(info)) as? [String: Any])
    #expect(obj["template_render_ok"] as? Bool == false)
    #expect(obj.keys.contains("template_render_ok"))
    #expect(try JSONDecoder().decode(ModelInfo.self, from: encoder.encode(info)) == info)

    // nil → key omitted entirely (wire-identical to an old provider).
    info = ModelInfo(id: "org/m", sizeBytes: 1024, estimatedMemoryGb: 1.5)
    obj = try #require(try JSONSerialization.jsonObject(with: encoder.encode(info)) as? [String: Any])
    #expect(obj.keys.contains("template_render_ok") == false)
    let decoded = try JSONDecoder().decode(ModelInfo.self, from: encoder.encode(info))
    #expect(decoded.templateRenderOK == nil)
    #expect(decoded == info)

    // Decodes a Go-emitted wire form carrying the field (protocol symmetry).
    let goWire = #"{"id":"org/m","size_bytes":1024,"estimated_memory_gb":1.5,"template_render_ok":false}"#
    let fromGo = try JSONDecoder().decode(ModelInfo.self, from: Data(goWire.utf8))
    #expect(fromGo.templateRenderOK == false)
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
            totalMemoryGb: 36
        )
    ))

    let data = try ProviderProtocolCodec.encodeProviderMessage(heartbeat)
    let object = try jsonObject(data)
    let capacity = object["backend_capacity"] as? [String: Any]
    let slot = (capacity?["slots"] as? [[String: Any]])?.first

    #expect(capacity?["gpu_memory_active_gb"] as? Double == 5.5)
    #expect(capacity?["gpu_memory_peak_gb"] as? Double == 6.5)
    #expect(capacity?["gpu_memory_cache_gb"] as? Double == 1.5)
    #expect(capacity?["total_memory_gb"] as? Double == 36)
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

@Test func inferenceRequestCacheEnvelopeFieldsRoundTripAndRemainOptional() throws {
    let scoped = CoordinatorMessage.inferenceRequest(.init(
        requestId: "req-cache",
        encryptedBody: EncryptedPayload(ephemeralPublicKey: "a", ciphertext: "b"),
        cacheReceiptNonce: "nonce-1",
        cacheScope: "account-route-key",
        prefixCacheProtocol: 2,
        toolSchemaMetadataProtocol: 1))
    let data = try ProviderProtocolCodec.encodeCoordinatorMessage(scoped)
    let object = try jsonObject(data)
    #expect(object["cache_receipt_nonce"] as? String == "nonce-1")
    #expect(object["cache_scope"] as? String == "account-route-key")
    #expect(object["prefix_cache_protocol"] as? Int == 2)
    #expect(object["tool_schema_metadata_protocol"] as? Int == 1)
    #expect(try ProviderProtocolCodec.decodeCoordinatorMessage(from: data) == scoped)

    let legacy = #"{"type":"inference_request","request_id":"r","body":null}"#
    guard case .inferenceRequest(let decoded) = try ProviderProtocolCodec.decodeCoordinatorMessage(
        from: Data(legacy.utf8))
    else { throw TestFailure.unexpectedMessage }
    #expect(decoded.cacheReceiptNonce == nil)
    #expect(decoded.cacheScope == nil)
    #expect(decoded.prefixCacheProtocol == nil)
    #expect(decoded.toolSchemaMetadataProtocol == nil)
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

// The v0.8.0 paged-KV rollout discriminator. `kvBackend` is `String?`, not
// `String`, and encodes with `encodeIfPresent` rather than the non-zero/false
// omission every other additive field here uses: a pre-0.8.0 provider omits
// `kv_backend` entirely and nil MUST stay distinguishable from an explicit
// value, or the coordinator books every legacy provider as a contiguous
// sample and the rollout A/B is measuring its own blind spot. Mirrors
// `KVBackend *string` + `omitempty` in coordinator/protocol/messages.go; the
// Go-side triple lives in messages_backend_capacity_test.go.
//
// BOTH directions on purpose. `BackendSlotCapacity` hand-rolls CodingKeys,
// `init(from:)` and `encode(to:)`, so one wire field costs six coordinated
// edits — and an encode-only assertion still passes when `init(from:)` forgot
// the key.
@Test func backendSlotCapacityRoundTripsKVBackendDiscriminator() throws {
    // 1. PRESENT — both shipped kinds survive encode → wire → decode.
    for kind in ["paged", "contiguous"] {
        let slot = BackendSlotCapacity(
            model: "gemma-4-26b-qat-4bit",
            state: "running",
            numRunning: 1,
            numWaiting: 0,
            activeTokens: 128,
            maxTokensPotential: 512,
            kvBackend: kind)
        let encoded = try JSONEncoder().encode(slot)
        let object = try jsonObject(encoded)
        #expect(object["kv_backend"] as? String == kind)
        let decoded = try JSONDecoder().decode(BackendSlotCapacity.self, from: encoded)
        #expect(decoded.kvBackend == kind)
    }

    // What the provider actually puts in that field is the RESOLVED engine
    // kind (EngineV2Bridge+Capacity passes `kvBackendKind.rawValue`), so pin
    // the two literals the wire can carry — renaming a case would otherwise
    // change the wire silently.
    #expect(EngineV2KVBackendKind.paged.rawValue == "paged")
    #expect(EngineV2KVBackendKind.contiguous.rawValue == "contiguous")

    // 2. OMITTED — a pre-0.8.0 payload decodes to nil (UNKNOWN, never
    //    "contiguous"), and a slot that never sets it re-encodes without the
    //    key, so the wire shape older consumers see is unchanged.
    let legacyRaw = #"{"model":"qwen","state":"running","num_running":2,"num_waiting":0,"active_tokens":3000,"max_tokens_potential":8000}"#
    let legacy = try JSONDecoder().decode(BackendSlotCapacity.self, from: Data(legacyRaw.utf8))
    #expect(legacy.kvBackend == nil)
    let legacyReencoded = try jsonObject(JSONEncoder().encode(legacy))
    #expect(legacyReencoded["kv_backend"] == nil)

    // 3. EXPLICIT EMPTY — survives both directions and stays distinct from
    //    omission. This is the case a plain `String` (or the `encodeIfNonZero`
    //    treatment the counters get) would silently collapse into "unknown".
    let emptyRaw = #"{"model":"qwen","state":"running","num_running":1,"num_waiting":0,"active_tokens":0,"max_tokens_potential":0,"kv_backend":""}"#
    let empty = try JSONDecoder().decode(BackendSlotCapacity.self, from: Data(emptyRaw.utf8))
    #expect(empty.kvBackend == "")
    #expect(empty.kvBackend != legacy.kvBackend)
    let emptyReencoded = try jsonObject(JSONEncoder().encode(empty))
    #expect(emptyReencoded["kv_backend"] as? String == "")
}

// The other half of the rollout discriminator, with the OPPOSITE omission
// rule: `kv_backend_fallback_reason` absent means the slot did NOT degrade,
// where `kv_backend` absent means unknown. Mirrors
// `KVBackendFallbackReason *string` + `omitempty` in
// coordinator/protocol/messages.go; the Go-side triple lives in
// messages_backend_capacity_test.go.
//
// Both halves are asserted. A field that is always present is not a signal:
// the degraded slot carrying its reason is worth nothing unless the healthy
// slot provably keeps the key OFF the wire.
@Test func backendSlotCapacityRoundTripsKVBackendFallbackReason() throws {
    // 1. DEGRADED — the slot was configured paged, paged did not happen, it
    //    serves contiguous and says why.
    let reason = "pool_construction_capacity: needed 3221225472, available 2147483648"
    let degraded = BackendSlotCapacity(
        model: "gemma-4-26b-qat-4bit",
        state: "running",
        numRunning: 1,
        numWaiting: 0,
        activeTokens: 128,
        maxTokensPotential: 512,
        kvBackend: "contiguous",
        kvBackendFallbackReason: reason)
    let degradedEncoded = try JSONEncoder().encode(degraded)
    let degradedObject = try jsonObject(degradedEncoded)
    #expect(degradedObject["kv_backend"] as? String == "contiguous")
    #expect(degradedObject["kv_backend_fallback_reason"] as? String == reason)
    let degradedDecoded = try JSONDecoder().decode(
        BackendSlotCapacity.self, from: degradedEncoded)
    #expect(degradedDecoded.kvBackendFallbackReason == reason)

    // 2. NOT DEGRADED — an operator who configured contiguous. Same resolved
    //    kind; the key must be ABSENT, not "" and not "none".
    let chosen = BackendSlotCapacity(
        model: "gemma-4-26b-qat-4bit",
        state: "running",
        numRunning: 1,
        numWaiting: 0,
        activeTokens: 128,
        maxTokensPotential: 512,
        kvBackend: "contiguous")
    let chosenEncoded = try JSONEncoder().encode(chosen)
    let chosenObject = try jsonObject(chosenEncoded)
    #expect(chosenObject["kv_backend"] as? String == "contiguous")
    #expect(chosenObject["kv_backend_fallback_reason"] == nil)
    let chosenDecoded = try JSONDecoder().decode(
        BackendSlotCapacity.self, from: chosenEncoded)
    #expect(chosenDecoded.kvBackendFallbackReason == nil)

    // The whole point: two slots reporting the same resolved kind are now
    // distinguishable on the wire. Before this key they were identical.
    #expect(degraded.kvBackend == chosen.kvBackend)
    #expect(degradedEncoded != chosenEncoded)

    // 3. PRE-0.8.0 — neither key. Absence of the reason here is NOT "did not
    //    degrade": with no `kv_backend` either, the slot is unknown, which is
    //    why the coordinator reads the two together.
    let legacyRaw = #"{"model":"qwen","state":"running","num_running":2,"num_waiting":0,"active_tokens":3000,"max_tokens_potential":8000}"#
    let legacy = try JSONDecoder().decode(
        BackendSlotCapacity.self, from: Data(legacyRaw.utf8))
    #expect(legacy.kvBackend == nil)
    #expect(legacy.kvBackendFallbackReason == nil)
    let legacyReencoded = try jsonObject(JSONEncoder().encode(legacy))
    #expect(legacyReencoded["kv_backend_fallback_reason"] == nil)

    // 4. Decode is wired too — an encode-only assertion still passes when
    //    `init(from:)` forgot the key, and then the coordinator's own
    //    heartbeat round-trip would drop it.
    let wire = #"{"model":"qwen","state":"running","num_running":1,"num_waiting":0,"active_tokens":0,"max_tokens_potential":0,"kv_backend":"contiguous","kv_backend_fallback_reason":"kill_switch"}"#
    let fromWire = try JSONDecoder().decode(
        BackendSlotCapacity.self, from: Data(wire.utf8))
    #expect(fromWire.kvBackendFallbackReason == "kill_switch")
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw TestFailure.notJSONObject
    }
    return object
}

private enum TestFailure: Error {
    case notJSONObject
    case unexpectedMessage
}
