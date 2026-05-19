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
