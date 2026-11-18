import Foundation
import Testing
@testable import ProviderCore

/// The endpoint key that requests are encrypted to lives in one provider
/// process only: every process generates a fresh one, nothing restores one
/// from stored bytes, and it is never serialized or printed.
@Suite struct EndpointKeyLifecycleTests {
    @Test func everyGenerationIsFresh() {
        let keys = (0 ..< 64).map { _ in NodeKeyPair.generate().publicKeyBase64 }
        #expect(Set(keys).count == keys.count)
    }

    /// Two provider loops stand for two processes (a restart or an update):
    /// the later one never registers the earlier one's key.
    @Test func everyProviderProcessRegistersItsOwnKey() async throws {
        let hardware = HardwareInfo(machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4,
            chipTier: .max, memoryGb: 128, memoryAvailableGb: 124,
            cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4), gpuCores: 40, memoryBandwidthGbs: 546)
        let config = ProviderLoopConfig(coordinatorURL: "ws://127.0.0.1:0/unused", hardware: hardware, models: [],
            config: ProviderConfig(provider: ProviderSettings(name: "endpoint-key-lifecycle-test")))
        let before = try ProviderLoop(config: config, attestationSigner: nil)
        let after = try ProviderLoop(config: config, attestationSigner: nil)
        #expect(await before.keyPair.publicKeyBase64 != after.keyPair.publicKeyBase64)
    }

    @Test func theSecretIsNeitherSerializableNorPrinted() throws {
        let secret = Data((1 ... 32).map { UInt8($0) })
        let key = try NodeKeyPair(rawSecret: secret)
        #expect(!(NodeKeyPair.self is any Encodable.Type))
        var dumped = ""
        dump(key, to: &dumped)
        let hex = secret.map { String(format: "%02x", $0) }.joined()
        for text in [String(describing: key), String(reflecting: key), key.debugDescription, dumped] {
            #expect(!text.contains(secret.base64EncodedString()) && !text.contains(hex), "\(text)")
        }
    }

    /// No production source restores a key from bytes (the initializer is
    /// internal and kept for fixed test vectors).
    @Test func noProductionSourceRestoresAKey() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var callers: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "NodeKeyPair.swift" {
            if try String(contentsOf: url, encoding: .utf8).contains("NodeKeyPair(rawSecret") { callers.append(url.path) }
        }
        #expect(callers.isEmpty, "\(callers)")
    }
}
