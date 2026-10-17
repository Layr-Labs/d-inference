import Foundation
import Testing
@testable import DarkbloomClusterRuntime

// The host gate every resident load and every request re-check passes through.
// Observations here are constructed, never sampled: the policy is pure.

@Suite("Stage load resource policy (constructed observations)")
struct StageLoadResourcePolicyTests {
    private static let gib = QwenDenseStageLoadPolicy.gib
    private static let page = 16_384

    /// A consistent observation: `free` GiB of actual free pages on a 128 GiB Mac.
    private static func observation(freeGiB: Int = 64, pressure: Int = 1, swapBytes: Int = 0,
                                    completed: UInt64 = 1_000, started: UInt64 = 900) -> QwenDenseStageLoadOSObservation {
        let free = freeGiB * gib / page, inactive = 1_000, speculative = 500
        return .init(startedNanoseconds: started, completedNanoseconds: completed,
            timestampUTC: "2026-10-08T00:00:00Z", physicalMemoryBytes: 128 * gib, pageSizeBytes: page,
            kernelFreePages: free + speculative, freePages: free, inactivePages: inactive,
            speculativePages: speculative, actualFreeBytes: free * page,
            estimatedReclaimableBytes: (free + inactive + speculative) * page,
            pressureLevel: pressure, swapUsedBytes: swapBytes)
    }

    private static func admits(_ value: QwenDenseStageLoadOSObservation, now: UInt64 = 1_100) -> Bool {
        (try? QwenDenseStageLoadPolicy.requireInitial(value, now: now)) != nil
    }

    @Test func aQuietMacWithNoSwapIsAdmitted() {
        #expect(Self.admits(Self.observation()))
    }

    @Test func swapLeftFromEarlierIsAdmittedWhilePressureIsNormal() {
        // The case that kept a daily-use Mac from ever serving: gigabytes
        // swapped out long ago, 64 GiB free now, kernel pressure normal.
        #expect(Self.admits(Self.observation(swapBytes: 3 * Self.gib)))
        #expect(QwenDenseStageLoadPolicy.swapIsAcceptable(swapUsedBytes: 3 * Self.gib, pressureLevel: 1))
    }

    @Test func swapUnderWarningPressureIsRefused() {
        #expect(!Self.admits(Self.observation(pressure: 2, swapBytes: 1)))
        #expect(!QwenDenseStageLoadPolicy.swapIsAcceptable(swapUsedBytes: 1, pressureLevel: 2))
        // Warning pressure alone, with nothing swapped, was admitted before and still is.
        #expect(Self.admits(Self.observation(pressure: 2)))
    }

    @Test func criticalPressureIsRefusedWithOrWithoutSwap() {
        #expect(!Self.admits(Self.observation(pressure: 4)))
        #expect(!Self.admits(Self.observation(pressure: 4, swapBytes: Self.gib)))
    }

    @Test func swapNeverSubstitutesForFreePages() {
        // Below the 6 GiB floor the load is refused whatever the swap state.
        #expect(!Self.admits(Self.observation(freeGiB: 5)))
        #expect(!Self.admits(Self.observation(freeGiB: 5, swapBytes: 3 * Self.gib)))
        #expect(Self.admits(Self.observation(freeGiB: 6, swapBytes: 3 * Self.gib)))
    }

    @Test func staleOrInconsistentObservationsAreRefused() {
        // Older than one second at decision time.
        #expect(!Self.admits(Self.observation(), now: 1_000 + 1_000_000_001))
        // Completed before it started, or negative swap.
        #expect(!Self.admits(Self.observation(completed: 800, started: 900)))
        #expect(!Self.admits(Self.observation(swapBytes: -1)))
        // Free bytes that do not match the page counters.
        let base = Self.observation()
        let forged = QwenDenseStageLoadOSObservation(startedNanoseconds: base.startedNanoseconds,
            completedNanoseconds: base.completedNanoseconds, timestampUTC: base.timestampUTC,
            physicalMemoryBytes: base.physicalMemoryBytes, pageSizeBytes: base.pageSizeBytes,
            kernelFreePages: base.kernelFreePages, freePages: base.freePages,
            inactivePages: base.inactivePages, speculativePages: base.speculativePages,
            actualFreeBytes: base.actualFreeBytes + Self.page,
            estimatedReclaimableBytes: base.estimatedReclaimableBytes,
            pressureLevel: base.pressureLevel, swapUsedBytes: base.swapUsedBytes)
        #expect(!Self.admits(forged))
    }
}
