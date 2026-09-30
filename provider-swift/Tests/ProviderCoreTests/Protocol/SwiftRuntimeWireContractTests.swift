import Foundation
import Testing
@testable import ProviderCore

@Test func phase6RegistrationUsesCutoverBackendAndOmitsDeprecatedRuntimeHashes() throws {
    let config = CoordinatorClientConfig(
        url: "wss://api.darkbloom.dev/ws/provider",
        hardware: phase6Hardware(),
        models: [phase6Model()],
        backendName: "mlx-swift",
        publicKey: "cHVibGljLWtleS1wbGFjZWhvbGRlci0zMi1ieXRlcw==",
        runtimeHashes: RuntimeHashes(templateHashes: ["qwen3.5": "templatehash"])
    )

    let data = try CoordinatorClientCodec.encodeRegistration(
        from: config,
        version: "0.4.0-swift",
        privacyCapabilities: phase6PrivacyCapabilities()
    )
    let object = try phase6JSONObject(data)

    #expect(object["type"] as? String == "register")
    #expect(object["backend"] as? String == "mlx-swift")
    #expect(object["version"] as? String == "0.4.0-swift")
    #expect(object["encrypted_response_chunks"] as? Bool == true)
    #expect(object["python_hash"] == nil)
    #expect(object["runtime_hash"] == nil)
    #expect((object["template_hashes"] as? [String: String])?["qwen3.5"] == "templatehash")

    let decoded = try ProviderProtocolCodec.decodeProviderMessage(from: data)
    guard case .register(let register) = decoded else {
        throw Phase6TestFailure.unexpectedMessage
    }
    #expect(register.backend == "mlx-swift")
}

private func phase6Hardware() -> HardwareInfo {
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

private func phase6Model() -> ModelInfo {
    ModelInfo(
        id: "mlx-community/Qwen2.5-7B-4bit",
        modelType: "qwen2",
        quantization: "4bit",
        sizeBytes: 4_000_000_000,
        estimatedMemoryGb: 4.5
    )
}

private func phase6PrivacyCapabilities() -> PrivacyCapabilities {
    PrivacyCapabilities(
        textBackendInprocess: true,
        textProxyDisabled: true,
        sipEnabled: true,
        antiDebugEnabled: true,
        coreDumpsDisabled: true,
        envScrubbed: true
    )
}

private func phase6JSONObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw Phase6TestFailure.notJSONObject
    }
    return object
}

private enum Phase6TestFailure: Error {
    case notJSONObject
    case unexpectedMessage
}
