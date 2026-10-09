import Foundation
import Testing

@testable import ProviderCore

@Suite("Diffusion prefix precision guard")
struct EngineV2DiffusionPrefixPrecisionTests {
    @Test(arguments: [EngineV2KVQuantizationSelection.balanced, .k8v4, .k8v8])
    func packedPrefixRefusesBeforeResidentConfiguration(selection: EngineV2KVQuantizationSelection) async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prepared = try await EngineV2SlotFactory.prepareDiffusionPrefixCache(
            modelId: "diffusion-fixture", modelDirectory: missing, weightHash: nil,
            kvBytesCapacity: 1 << 30, kvBudget: nil,
            environment: [PrefixCachePolicy.environmentFlag: "1",
                          PrefixCachePolicy.memoryEnvironmentFlag: "1"],
            persistentTestNamespace: nil, pageBacked: true, kvQuantization: selection)
        #expect(prepared.snapshots == nil && prepared.store == nil && !prepared.retainMemory)
        #expect(prepared.status.state == .disabled && prepared.status.reason == .unsupportedLayout)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func nativeDisabledPrefixPreservesExistingPolicy() async throws {
        let prepared = try await EngineV2SlotFactory.prepareDiffusionPrefixCache(
            modelId: "diffusion-fixture", modelDirectory: nil, weightHash: nil,
            kvBytesCapacity: 1 << 30, kvBudget: nil,
            environment: [PrefixCachePolicy.environmentFlag: "0"],
            persistentTestNamespace: nil, pageBacked: true, kvQuantization: .native)
        #expect(prepared.snapshots == nil && prepared.store == nil && !prepared.retainMemory)
        #expect(prepared.status.state == .disabled && prepared.status.reason == .configDisabled)
    }
}
