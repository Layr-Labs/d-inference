import Foundation
import Testing
@testable import ProviderCore

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
    let message = ProviderMessage.register(ProviderMessage.Register(
        hardware: sampleHardware(),
        models: [sampleModel()],
        backend: "mlx_swift_lm",
        attestation: RawJSON(rawBytes: Data(raw.utf8)),
        privateOnly: true,
        apnsDeviceToken: "cb1ceb489ec9",
        apnsEnvironment: "production"
    ))
    let data = try ProviderProtocolCodec.encodeProviderMessage(message)
    let object = try jsonObject(data)
    #expect(object["apns_device_token"] as? String == "cb1ceb489ec9")
    #expect(object["apns_environment"] as? String == "production")
    #expect(object["private_only"] as? Bool == true)
    // Raw attestation bytes preserved verbatim (the reason this path exists).
    let json = String(data: data, encoding: .utf8) ?? ""
    #expect(json.contains(#""attestation":\#(raw)"#))

    let decoded = try ProviderProtocolCodec.decodeProviderMessage(from: data)
    guard case .register(let r) = decoded else { throw TestFailure.unexpectedMessage }
    #expect(r.apnsDeviceToken == "cb1ceb489ec9")
    #expect(r.apnsEnvironment == "production")
    #expect(r.privateOnly == true)
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
            hypervisorActive: true,
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
        activeTokenBudgetUsed: 28_000,
        activeTokenBudgetMax: 32_768,
        queuedTokenBudget: 4_096,
        kvBytesPerToken: 393_216
    )

    let data = try JSONEncoder().encode(slot)
    let object = try jsonObject(data)
    #expect(object["max_concurrency"] as? Int == 6)
    #expect(object["observed_decode_tps"] as? Double == 85.5)
    #expect(object["active_token_budget_used"] as? Int == 28_000)
    #expect(object["active_token_budget_max"] as? Int == 32_768)
    #expect(object["queued_token_budget"] as? Int == 4_096)
    #expect(object["kv_bytes_per_token"] as? Int == 393_216)

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
    #expect(decoded.activeTokenBudgetUsed == 0)
    #expect(decoded.activeTokenBudgetMax == 0)
    #expect(decoded.queuedTokenBudget == 0)
    #expect(decoded.kvBytesPerToken == 0)
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
        activeTokenBudgetUsed: 0,
        activeTokenBudgetMax: 0,
        queuedTokenBudget: 0,
        kvBytesPerToken: 0
    )

    let object = try jsonObject(JSONEncoder().encode(slot))

    #expect(object["active_tokens"] as? Int == 0)
    #expect(object["max_tokens_potential"] as? Int == 0)
    #expect(object["max_concurrency"] == nil)
    #expect(object["observed_decode_tps"] == nil)
    #expect(object["active_token_budget_used"] == nil)
    #expect(object["active_token_budget_max"] == nil)
    #expect(object["queued_token_budget"] == nil)
    #expect(object["kv_bytes_per_token"] == nil)
}

@Test func privacyCapabilitiesDecodesMissingHypervisorActiveAsFalse() throws {
    let raw = #"{"text_backend_inprocess":true,"text_proxy_disabled":true,"python_runtime_locked":true,"dangerous_modules_blocked":true,"sip_enabled":true,"anti_debug_enabled":true,"core_dumps_disabled":true,"env_scrubbed":true}"#
    let decoded = try JSONDecoder().decode(PrivacyCapabilities.self, from: Data(raw.utf8))

    #expect(decoded.hypervisorActive == false)
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
                activeTokenBudgetUsed: 5000,
                activeTokenBudgetMax: 12000,
                queuedTokenBudget: 7000,
                kvBytesPerToken: 262144
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
    #expect(slot?["active_token_budget_used"] as? Int == 5000)
    #expect(slot?["active_token_budget_max"] as? Int == 12000)
    #expect(slot?["queued_token_budget"] as? Int == 7000)
    #expect(slot?["kv_bytes_per_token"] as? Int == 262144)
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
        envScrubbed: true,
        hypervisorActive: false
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
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw TestFailure.notJSONObject
    }
    return object
}

private enum TestFailure: Error {
    case notJSONObject
    case unexpectedMessage
}
