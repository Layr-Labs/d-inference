#if CBV2_WINDOW_STATE_FIXTURE
import Foundation
import MLX

@_spi(ClusterTesting) public enum WindowedRequestStateCheck {
    public static func run() throws -> Data {
        try MLX.withError { native in
            let start = DispatchTime.now().uptimeNanoseconds
            let baseline = Memory.activeMemory
            func check() throws {
                try native.check()
                guard DispatchTime.now().uptimeNanoseconds - start < 55_000_000_000,
                      Memory.activeMemory <= baseline + 64 * 1024 * 1024 else {
                    throw ProbeError("Windowed fixture exceeds fixed lifetime or native-active envelope")
                }
                try QwenResidentResourceEnvironment.require()
            }
            do {
                try check()
                let groups = try autoreleasepool {
                    try WindowedStateChronologyCheck.run(check: check)
                    + WindowedStateFailureCheck.run(check: check)
                    + WindowedStateLegacyQwenCheck.run(check: check)
                }
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try check()
                Memory.clearCache(); try check()
                return try JSONSerialization.data(withJSONObject: [
                    "fixture": "actual-cbv2-mixed-full-window-state", "passed": groups,
                    "observedDTypes": ["bfloat16", "float32"], "windowTokens": 4,
                    "maximumTokens": 32, "maximumChunkTokens": 7,
                    "exactNativeKVCapacityBytes": 8192, "conservativeBackendReservationBytes": 12288,
                    "retainedWindowTemporaryBoundBytes": 14336,
                    "maximumNativeActiveIncrementBytes": 64 * 1024 * 1024,
                    "sharedStateAndCacheExecuted": true, "actualPrefill2Decode1Probe": true,
                    "legacyQwenActualForward": true, "gemmaModelExecuted": false,
                    "registeredWeightsLoaded": false, "outerGemmaAdmissionQualified": false,
                    "distributedExecutionQualified": false,
                ], options: [.sortedKeys])
            } catch {
                Stream.gpu.synchronize(); Stream.cpu.synchronize()
                try native.check()
                Memory.clearCache(); try native.check()
                throw error
            }
        }
    }
}
#endif
