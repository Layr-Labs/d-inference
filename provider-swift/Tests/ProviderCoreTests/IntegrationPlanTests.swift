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
    #expect(register.pythonHash == nil)
    #expect(register.runtimeHash == nil)
}

@Test func phase6ReleasePayloadForSwiftRuntimeOmitsDeprecatedRuntimeHashFields() throws {
    let payload = SwiftReleaseRegistrationPayload(
        version: "0.4.0-swift",
        platform: "macos-arm64",
        binaryHash: String(repeating: "a", count: 64),
        bundleHash: String(repeating: "b", count: 64),
        templateHashes: "qwen3.5=templatehash",
        url: "https://pub.example/releases/v0.4.0-swift/darkbloom-bundle-macos-arm64.tar.gz",
        changelog: "Swift provider cutover test payload"
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(payload)
    let object = try phase6JSONObject(data)

    #expect(object["version"] as? String == "0.4.0-swift")
    #expect(object["platform"] as? String == "macos-arm64")
    #expect(object["binary_hash"] as? String == String(repeating: "a", count: 64))
    #expect(object["bundle_hash"] as? String == String(repeating: "b", count: 64))
    #expect(object["python_hash"] == nil)
    #expect(object["runtime_hash"] == nil)
}

private struct SwiftReleaseRegistrationPayload: Encodable {
    var version: String
    var platform: String
    var binaryHash: String
    var bundleHash: String
    var templateHashes: String
    var url: String
    var changelog: String

    enum CodingKeys: String, CodingKey {
        case version
        case platform
        case binaryHash = "binary_hash"
        case bundleHash = "bundle_hash"
        case templateHashes = "template_hashes"
        case url
        case changelog
    }
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
        pythonRuntimeLocked: true,
        dangerousModulesBlocked: true,
        sipEnabled: true,
        antiDebugEnabled: true,
        coreDumpsDisabled: true,
        envScrubbed: true,
        hypervisorActive: false
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
