import Foundation
import ProviderCore
import Testing
@testable import darkbloom

@Suite("model disk inventory")
struct ModelsInventoryTests {
    private let enabled = ModelInfo(id: "org/enabled", sizeBytes: 1, estimatedMemoryGb: 1)
    private let disabled = ModelInfo(id: "org/disabled", sizeBytes: 2, estimatedMemoryGb: 2)
    private let oversized = ModelInfo(id: "org/oversized", sizeBytes: 100, estimatedMemoryGb: 100)

    private var snapshot: RuntimeSnapshot {
        var config = ProviderConfig.defaultForHardware(HardwareInfo(
            machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
            memoryGb: 32, memoryAvailableGb: 8,
            cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546))
        config.backend.enabledModels = [enabled.id]
        return RuntimeSnapshot(
            configPath: URL(fileURLWithPath: "/tmp/model-inventory-unused.toml"),
            configFileExists: true, config: config,
            hardware: nil, hardwareError: nil,
            models: [enabled, disabled])
    }

    @Test("--all retains disabled and memory-filtered models, even without hardware detection")
    func allListsCompleteDiskInventory() throws {
        let command = try Models.List.parse(["--json", "--all"])
        let inventory = [enabled, disabled, oversized]
        #expect(command.listedModels(from: snapshot, scanAll: { inventory }) == inventory)
    }

    @Test("default listing preserves configured and memory-filtered selection")
    func defaultListingPreservesSelection() throws {
        let command = try Models.List.parse(["--json"])
        let models = command.listedModels(from: snapshot, scanAll: {
            Issue.record("default listing must keep the runtime snapshot")
            return []
        })
        #expect(models == [enabled])
    }
}
