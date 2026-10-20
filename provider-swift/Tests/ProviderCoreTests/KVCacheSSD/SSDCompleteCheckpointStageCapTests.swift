import Foundation
import Testing
@testable import ProviderCore

@Suite("Complete-checkpoint stage cap by physical memory")
struct SSDCompleteCheckpointStageCapTests {
    private static let gib: UInt64 = 1 << 30

    @Test("below the large-memory threshold the general defaults apply",
          arguments: [UInt64(16), 24, 36, 47])
    func smallMemoryKeepsDefaults(memoryGiB: UInt64) {
        let memory = memoryGiB * Self.gib
        #expect(SSDPrefixCachePolicy.completeCheckpointMaxStageBytes(environment: [:], physicalMemoryBytes: memory)
            == SSDPrefixCachePolicy.defaultMaxStageBytes)
        #expect(SSDPrefixCachePolicy.completeCheckpointMaxStageMillis(environment: [:], physicalMemoryBytes: memory)
            == SSDPrefixCachePolicy.defaultMaxStageMillis)
    }

    @Test("large-memory Macs default to a deeper complete-checkpoint cap",
          arguments: [UInt64(48), 64, 96, 128, 192, 512])
    func largeMemoryRaisesDefaults(memoryGiB: UInt64) {
        let memory = memoryGiB * Self.gib
        #expect(SSDPrefixCachePolicy.completeCheckpointMaxStageBytes(environment: [:], physicalMemoryBytes: memory)
            == SSDPrefixCachePolicy.largeMemoryCompleteCheckpointStageBytes)
        #expect(SSDPrefixCachePolicy.completeCheckpointMaxStageMillis(environment: [:], physicalMemoryBytes: memory)
            == SSDPrefixCachePolicy.largeMemoryCompleteCheckpointStageMillis)
    }

    @Test("the time cap admits a full-size file at the conservative estimate rate")
    func timeCapAdmitsByteCap() {
        // The store's time check sees the payload plus its 1 MiB file-framing allowance.
        #expect(SSDPrefixCachePolicy.estimatedStageMillis(
            bytes: SSDPrefixCachePolicy.largeMemoryCompleteCheckpointStageBytes + (1 << 20))
            <= SSDPrefixCachePolicy.largeMemoryCompleteCheckpointStageMillis)
    }

    @Test("explicit settings win at every memory size", arguments: [UInt64(36), 128])
    func explicitSettingsWin(memoryGiB: UInt64) {
        let environment = [SSDPrefixCachePolicy.maxStageMBFlag: "512",
                           SSDPrefixCachePolicy.maxStageMillisFlag: "300"]
        let memory = memoryGiB * Self.gib
        #expect(SSDPrefixCachePolicy.completeCheckpointMaxStageBytes(
            environment: environment, physicalMemoryBytes: memory) == 512 * 1_048_576)
        #expect(SSDPrefixCachePolicy.completeCheckpointMaxStageMillis(
            environment: environment, physicalMemoryBytes: memory) == 300)
    }

    @Test("invalid settings fall back to the memory-based default")
    func invalidSettingsFallBack() {
        let environment = [SSDPrefixCachePolicy.maxStageMBFlag: "0",
                           SSDPrefixCachePolicy.maxStageMillisFlag: "-5"]
        #expect(SSDPrefixCachePolicy.completeCheckpointMaxStageBytes(
            environment: environment, physicalMemoryBytes: 128 * Self.gib)
            == SSDPrefixCachePolicy.largeMemoryCompleteCheckpointStageBytes)
        #expect(SSDPrefixCachePolicy.completeCheckpointMaxStageMillis(
            environment: environment, physicalMemoryBytes: 36 * Self.gib)
            == SSDPrefixCachePolicy.defaultMaxStageMillis)
    }

    @Test("attention block caches keep the general defaults on large-memory Macs")
    func attentionCapsUnchanged() {
        #expect(SSDPrefixCachePolicy.maxStageBytes(environment: [:]) == SSDPrefixCachePolicy.defaultMaxStageBytes)
        #expect(SSDPrefixCachePolicy.maxStageMillis(environment: [:]) == SSDPrefixCachePolicy.defaultMaxStageMillis)
    }
}
