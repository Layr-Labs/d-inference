import Foundation
import Testing
@testable import ProviderCore

@Suite("Complete-checkpoint stage cap by physical memory")
struct SSDCompleteCheckpointStageCapTests {
    private static let gib: UInt64 = 1 << 30
    /// The 256 GiB tier's byte cap, spelled out so this file also reads the
    /// default on builds without the tier.
    private static let twelveGiB = 12_288 * 1_048_576
    /// The complete-checkpoint-only setting, spelled out for the same reason.
    private static let checkpointKey = "DARKBLOOM_PREFIX_CACHE_SSD_CHECKPOINT_MAX_STAGE_MB"

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
          arguments: [UInt64(48), 64, 96, 128, 192, 255])
    func largeMemoryRaisesDefaults(memoryGiB: UInt64) {
        let memory = memoryGiB * Self.gib
        #expect(SSDPrefixCachePolicy.completeCheckpointMaxStageBytes(environment: [:], physicalMemoryBytes: memory)
            == SSDPrefixCachePolicy.largeMemoryCompleteCheckpointStageBytes)
        #expect(SSDPrefixCachePolicy.completeCheckpointMaxStageMillis(environment: [:], physicalMemoryBytes: memory)
            == SSDPrefixCachePolicy.largeMemoryCompleteCheckpointStageMillis)
    }

    @Test("Macs with 256 GiB or more default to a 12 GiB complete-checkpoint cap and the same time cap",
          arguments: [UInt64(256), 384, 512])
    func veryLargeMemoryRaisesTheByteCap(memoryGiB: UInt64) {
        let memory = memoryGiB * Self.gib
        #expect(SSDPrefixCachePolicy.completeCheckpointMaxStageBytes(environment: [:], physicalMemoryBytes: memory)
            == Self.twelveGiB)
        #expect(SSDPrefixCachePolicy.completeCheckpointMaxStageMillis(environment: [:], physicalMemoryBytes: memory)
            == SSDPrefixCachePolicy.largeMemoryCompleteCheckpointStageMillis)
    }

    @Test("the time cap admits a full-size file at the conservative estimate rate", arguments: [false, true])
    func timeCapAdmitsByteCap(veryLarge: Bool) {
        // The store's time check sees the payload plus its 1 MiB file-framing allowance.
        let cap = veryLarge ? Self.twelveGiB : SSDPrefixCachePolicy.largeMemoryCompleteCheckpointStageBytes
        #expect(SSDPrefixCachePolicy.estimatedStageMillis(bytes: cap + (1 << 20))
            <= SSDPrefixCachePolicy.largeMemoryCompleteCheckpointStageMillis)
    }

    @Test("explicit settings win at every memory size", arguments: [UInt64(36), 128, 512])
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
        #expect(SSDPrefixCachePolicy.completeCheckpointMaxStageBytes(
            environment: environment, physicalMemoryBytes: 512 * Self.gib) == Self.twelveGiB)
        #expect(SSDPrefixCachePolicy.completeCheckpointMaxStageMillis(
            environment: environment, physicalMemoryBytes: 36 * Self.gib)
            == SSDPrefixCachePolicy.defaultMaxStageMillis)
    }

    @Test("the checkpoint setting alone decides the complete-checkpoint cap and leaves attention staging alone",
          arguments: [7168, 4096])
    func checkpointSettingDecidesTheCheckpointCapOnly(megabytes: Int) {
        let environment = [Self.checkpointKey: "\(megabytes)"]
        #expect(SSDPrefixCachePolicy.completeCheckpointMaxStageBytes(
            environment: environment, physicalMemoryBytes: 512 * Self.gib) == megabytes * 1_048_576)
        #expect(SSDPrefixCachePolicy.maxStageBytes(environment: environment)
            == SSDPrefixCachePolicy.defaultMaxStageBytes)
    }

    @Test("the checkpoint setting wins over the general one, and an invalid value falls through to it")
    func checkpointSettingPrecedence() {
        let general = SSDPrefixCachePolicy.maxStageMBFlag
        let both = [Self.checkpointKey: "7168", general: "512"]
        #expect(SSDPrefixCachePolicy.completeCheckpointMaxStageBytes(
            environment: both, physicalMemoryBytes: 512 * Self.gib) == 7168 * 1_048_576)
        #expect(SSDPrefixCachePolicy.maxStageBytes(environment: both) == 512 * 1_048_576)
        #expect(SSDPrefixCachePolicy.completeCheckpointMaxStageBytes(
            environment: [Self.checkpointKey: "0", general: "512"], physicalMemoryBytes: 512 * Self.gib)
            == 512 * 1_048_576)
    }

    @Test("both settings reach the installed provider; the checkpoint one keeps a 256 GiB Mac at 7 GiB")
    func settingsReachTheInstalledProvider() {
        #expect(SSDPrefixCachePolicy.maxStageMBFlag == "DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MB")
        for key in [SSDPrefixCachePolicy.maxStageMBFlag, Self.checkpointKey] {
            #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key), "\(key)")
            #expect(!WatchdogAgent.passthroughEnvKeys.contains(key), "\(key)")
        }
        let foreground = [Self.checkpointKey: "7168", "UNRELATED_SECRET": "excluded"]
        let plist = LaunchAgent.makeServicePlist(
            label: LaunchAgent.label, programArguments: ["/test/darkbloom", "start", "--foreground"],
            logPath: "/test/provider.log", environment: foreground)
        let launchd = plist["EnvironmentVariables"] as? [String: String] ?? [:]
        #expect(launchd[Self.checkpointKey] == "7168")
        #expect(launchd["UNRELATED_SECRET"] == nil)
        #expect(SSDPrefixCachePolicy.completeCheckpointMaxStageBytes(
            environment: launchd, physicalMemoryBytes: 256 * Self.gib)
            == SSDPrefixCachePolicy.largeMemoryCompleteCheckpointStageBytes)
        #expect(SSDPrefixCachePolicy.maxStageBytes(environment: launchd)
            == SSDPrefixCachePolicy.defaultMaxStageBytes)
    }
}
