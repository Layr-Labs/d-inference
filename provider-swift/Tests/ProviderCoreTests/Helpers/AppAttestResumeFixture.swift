import Foundation
import Testing
@testable import ProviderCore

/// Shared with platform fixtures/app-attest-resumption-v1.json. Keys are public
/// deterministic test material, not provider credentials.
struct AppAttestResumeFixture: Decodable {
    let providerSecretHex: String
    let providerPublicKey: String
    let serverPublicKey: String
    let requestJson: String
    let requestCiphertext: String
    let responsePlaintextHex: String
    let responseCiphertext: String

    static let now = Date(timeIntervalSince1970: 1_791_590_401)
    static let id = Data(repeating: 1, count: 32).base64EncodedString()
    static let nonce = Data(repeating: 3, count: 32).base64EncodedString()

    init() throws {
        let url = try #require(Bundle.module.url(
            forResource: "app-attest-resumption-v1", withExtension: "json", subdirectory: "Fixtures"))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self = try decoder.decode(Self.self, from: Data(contentsOf: url))
    }

    var provider: NodeKeyPair { get throws { try NodeKeyPair(rawSecret: Data(hexString: providerSecretHex)) } }
    var server: NodeKeyPair { get throws { try NodeKeyPair(rawSecret: Data(32..<64)) } }
    var challenge: AppAttestResumeChallenge {
        AppAttestResumeChallenge(id: Self.id, encryptedChallenge: EncryptedPayload(
            ephemeralPublicKey: serverPublicKey, ciphertext: requestCiphertext))
    }

    func seal(_ plaintext: String, to endpoint: NodeKeyPair? = nil, id: String = Self.id) throws -> AppAttestResumeChallenge {
        let recipient = try endpoint ?? provider
        return try AppAttestResumeChallenge(id: id, encryptedChallenge: server.encryptPayload(
            recipientPublicKey: recipient.publicKeyBytes, plaintext: Data(plaintext.utf8)))
    }

    func open(_ response: AppAttestResumeResponse) throws -> Data {
        try server.decrypt(senderPublicKey: provider.publicKeyBytes,
            ciphertext: #require(Data(base64Encoded: response.ciphertext)))
    }

    func request(overrides: [String: Any]) throws -> String {
        var fields = try #require(JSONSerialization.jsonObject(with: Data(requestJson.utf8)) as? [String: Any])
        fields.merge(overrides) { _, new in new }
        return String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
    }

    static func config(url: String = "ws://127.0.0.1:1/ws/provider", publicKey: String? = nil,
        attestation: RawJSON? = nil) -> CoordinatorClientConfig {
        CoordinatorClientConfig(url: url, hardware: HardwareInfo(
            machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
            memoryGb: 128, memoryAvailableGb: 124, cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546), models: [], backendName: "mlx-swift",
            heartbeatInterval: 0.1, publicKey: publicKey, attestation: attestation,
            privacyCapabilities: PrivacyCapabilities(textBackendInprocess: true, textProxyDisabled: true,
                sipEnabled: true, antiDebugEnabled: true, coreDumpsDisabled: true, envScrubbed: true))
    }
}
