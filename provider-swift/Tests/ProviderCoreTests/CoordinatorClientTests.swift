import Foundation
import Testing
@testable import ProviderCore

@Test func coordinatorRegistrationEncodingUsesProtocolCodec() throws {
    let rawAttestation = #"{"signature":"sig","attestation":{"hardwareModel":"Mac16,5","sipEnabled":true}}"#
    let config = CoordinatorClientConfig(
        url: "wss://api.dev.darkbloom.xyz/v1/providers/ws",
        hardware: clientSampleHardware(),
        models: [clientSampleModel()],
        backendName: "mlx_swift_lm",
        publicKey: "cHVibGlj",
        walletAddress: "0x1234567890abcdef1234567890abcdef12345678",
        attestation: RawJSON(rawBytes: Data(rawAttestation.utf8)),
        authToken: "device-token",
        runtimeHashes: RuntimeHashes(
            pythonHash: nil,
            runtimeHash: "runtimehash",
            templateHashes: ["chatml": "templatehash"]
        )
    )

    let data = try CoordinatorClientCodec.encodeRegistration(
        from: config,
        version: "0.4.0-swift-test",
        privacyCapabilities: clientPrivacyCapabilities()
    )
    let json = String(data: data, encoding: .utf8) ?? ""
    let object = try clientJSONObject(data)

    #expect(object["type"] as? String == "register")
    #expect(object["backend"] as? String == "mlx_swift_lm")
    #expect(object["version"] as? String == "0.4.0-swift-test")
    #expect(object["public_key"] as? String == "cHVibGlj")
    #expect(object["auth_token"] as? String == "device-token")
    #expect(object["encrypted_response_chunks"] as? Bool == true)
    #expect(json.contains(#""attestation":\#(rawAttestation)"#))

    let decoded = try ProviderProtocolCodec.decodeProviderMessage(from: data)
    guard case .register(let register) = decoded else {
        throw ClientTestFailure.unexpectedMessage
    }
    #expect(register.attestation?.rawBytes == Data(rawAttestation.utf8))
    #expect(register.runtimeHash == "runtimehash")
    #expect(register.templateHashes["chatml"] == "templatehash")
    #expect(register.privacyCapabilities?.textBackendInprocess == true)
}

@Test func coordinatorOutboundMessagesUseProviderEnvelope() throws {
    let accepted = try CoordinatorClientCodec.encodeOutboundMessageString(
        .inferenceAccepted(requestId: "req-1")
    )
    #expect(accepted.contains(#""type":"inference_accepted""#))
    #expect(accepted.contains(#""request_id":"req-1""#))

    let chunk = try CoordinatorClientCodec.encodeOutboundMessageString(
        .inferenceChunk(
            requestId: "req-2",
            data: "",
            encryptedData: EncryptedPayload(ephemeralPublicKey: "ZXBo", ciphertext: "Y2lwaGVy")
        )
    )
    #expect(chunk.contains(#""type":"inference_response_chunk""#))
    #expect(!chunk.contains(#""data""#))
    #expect(chunk.contains(#""encrypted_data""#))

    let complete = try ProviderProtocolCodec.decodeProviderMessage(
        from: try CoordinatorClientCodec.encodeOutboundMessage(.inferenceComplete(
            requestId: "req-3",
            usage: UsageInfo(promptTokens: 10, completionTokens: 20),
            seSignature: "sig",
            responseHash: "hash"
        ))
    )
    #expect(complete == .inferenceComplete(ProviderMessage.InferenceComplete(
        requestId: "req-3",
        usage: UsageInfo(promptTokens: 10, completionTokens: 20),
        seSignature: "sig",
        responseHash: "hash"
    )))
}

@Test func coordinatorHeartbeatConstructionOmitRulesMatchProtocol() throws {
    let idle = CoordinatorClientCodec.heartbeatMessage(
        status: .idle,
        activeModel: nil,
        warmModels: [],
        stats: ProviderStats(requestsServed: 0, tokensGenerated: 0),
        systemMetrics: SystemMetrics(memoryPressure: 0, cpuUsage: 0, thermalState: .nominal),
        backendCapacity: nil
    )
    let idleJSON = String(
        data: try ProviderProtocolCodec.encodeProviderMessage(idle),
        encoding: .utf8
    ) ?? ""

    #expect(idleJSON.contains(#""type":"heartbeat""#))
    #expect(idleJSON.contains(#""status":"idle""#))
    #expect(!idleJSON.contains("active_model"))
    #expect(!idleJSON.contains("warm_models"))

    let serving = CoordinatorClientCodec.heartbeatMessage(
        status: .serving,
        activeModel: "model-a",
        warmModels: ["model-a"],
        stats: ProviderStats(requestsServed: 7, tokensGenerated: 800),
        systemMetrics: SystemMetrics(memoryPressure: 0.7, cpuUsage: 0.4, thermalState: .fair),
        backendCapacity: nil
    )
    let servingData = try ProviderProtocolCodec.encodeProviderMessage(serving)
    let servingObject = try clientJSONObject(servingData)
    #expect(servingObject["status"] as? String == "serving")
    #expect(servingObject["active_model"] as? String == "model-a")
    #expect(servingObject["warm_models"] as? [String] == ["model-a"])
}

@Test func coordinatorIncomingMessagesDecodeForDispatch() throws {
    let challenge = try CoordinatorClientCodec.decodeIncomingMessage(
        from: #"{"type":"attestation_challenge","nonce":"bm9uY2U=","timestamp":"2026-04-03T12:00:00Z"}"#
    )
    #expect(challenge == .attestationChallenge(CoordinatorMessage.AttestationChallenge(
        nonce: "bm9uY2U=",
        timestamp: "2026-04-03T12:00:00Z"
    )))

    let cancel = try CoordinatorClientCodec.decodeIncomingMessage(
        from: #"{"type":"cancel","request_id":"req-cancel"}"#
    )
    #expect(cancel == .cancel(CoordinatorMessage.Cancel(requestId: "req-cancel")))

    let runtimeStatus = try CoordinatorClientCodec.decodeIncomingMessage(
        from: #"{"type":"runtime_status","verified":false,"mismatches":[{"component":"runtime","expected":"a","got":"b"}]}"#
    )
    guard case .runtimeStatus(let status) = runtimeStatus else {
        throw ClientTestFailure.unexpectedMessage
    }
    #expect(status.verified == false)
    #expect(status.mismatches.first?.component == "runtime")
}

@Test func exponentialBackoffDoublesUntilMaximumAndResets() {
    var backoff = ExponentialBackoff(base: 1, max: 4)

    #expect(backoff.nextDelay() == 1)
    #expect(backoff.nextDelay() == 2)
    #expect(backoff.nextDelay() == 4)
    #expect(backoff.nextDelay() == 4)

    backoff.reset()
    #expect(backoff.nextDelay() == 1)
}

private func clientSampleHardware() -> HardwareInfo {
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

private func clientSampleModel() -> ModelInfo {
    ModelInfo(
        id: "mlx-community/Qwen2.5-7B-4bit",
        modelType: "qwen2",
        parameters: nil,
        quantization: "4bit",
        sizeBytes: 4_000_000_000,
        estimatedMemoryGb: 4.5
    )
}

private func clientPrivacyCapabilities() -> PrivacyCapabilities {
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

private func clientJSONObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ClientTestFailure.notJSONObject
    }
    return object
}

private enum ClientTestFailure: Error {
    case notJSONObject
    case unexpectedMessage
}
