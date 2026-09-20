import Foundation
import Testing

@testable import ProviderCore

/// Separately selected observation after real native unload. A delayed reload
/// here can diagnose reclaim latency but CANNOT pass the immediate reload gate.
@Suite("Flash-Next post-retirement reclaim diagnostic", .serialized)
struct FlashNextReclaimDiagnostics {
    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["DARKBLOOM_FLASH_NEXT_RECLAIM_DIAGNOSTIC"] == "1"
            && ProcessInfo.processInfo.environment["DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST"] == "1",
        "Requires explicit real-artifact reclaim diagnostics and exclusive GPU ownership"))
    func observesMetalAndOSRetirementWithoutChangingTheOriginalGate() async throws {
        try await FlashNextQuietCancellationReloadLiveTests().runReloadLifecycle { loop in
            await loop.recordFlashNextLifecycleMemory("diagnostic_reclaim_0ms")
            var prior = 0
            for elapsed in [10, 25, 50, 100, 250, 500, 1000, 2000] {
                try await Task.sleep(for: .milliseconds(elapsed - prior))
                await loop.recordFlashNextLifecycleMemory("diagnostic_reclaim_\(elapsed)ms")
                prior = elapsed
            }
            print("Flash-Next reclaim diagnostic: any later reload result is NOT the original immediate-reload qualification")
        }
    }
}
