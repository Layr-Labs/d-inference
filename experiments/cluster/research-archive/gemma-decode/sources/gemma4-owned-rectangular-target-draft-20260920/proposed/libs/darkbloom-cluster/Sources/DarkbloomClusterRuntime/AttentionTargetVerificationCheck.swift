#if CBV2_WINDOW_STATE_FIXTURE
import Foundation
import MLX

@_spi(ClusterTesting) public enum AttentionTargetVerificationCheck {
    public static func run() throws -> Data {
        try MLX.withError { native in
            let start = DispatchTime.now().uptimeNanoseconds, baseline = Memory.activeMemory
            func check() throws {
                try native.check()
                guard DispatchTime.now().uptimeNanoseconds - start < 55_000_000_000,
                      Memory.activeMemory <= baseline + 64 * 1024 * 1024 else {
                    throw ProbeError("Rectangular attention fixture exceeds lifetime or native-active allowance")
                }
                try QwenResidentResourceEnvironment.require()
            }
            do {
                try check()
                let groups = try AttentionVerificationPlanCheck.run()
                    + AttentionVerificationChronologyCheck.run(check: check)
                    + AttentionVerificationFailureCheck.run(check: check)
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try check()
                Memory.clearCache(); try check()
                return try JSONSerialization.data(withJSONObject: [
                    "fixture": "actual-owned-rectangular-attention-v1", "passed": groups,
                    "maximumVerificationWidth": 4, "actualPrefixCases": 56,
                    "actualFullWindowRows": true, "actualPrefill2Decode1Probe": true,
                    "modeledGemmaLayers": 30, "modeledSlidingLayers": 25, "modeledFullLayers": 5,
                    "sameShapeRollbackReference": true, "syntheticSerialOutputExact": true,
                    "maximumNativeActiveIncrementBytes": 64 * 1024 * 1024,
                    "gemmaWeightsExecuted": false, "modelBatchShapeNumericsQualified": false,
                    "assistantOrDistributedQualified": false, "wholeModelResourceQualified": false,
                ], options: [.sortedKeys])
            } catch {
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try native.check()
                Memory.clearCache(); try native.check(); throw error
            }
        }
    }
}
#endif
